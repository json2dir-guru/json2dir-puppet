# json2dir in the Puppet language: read a JSON document, validate all of it while the
# catalog is compiled (fail() aborts before anything is applied), then declare one `file`
# resource per entry and let `puppet apply` create the tree.
#
# Inputs (passed by the launcher as facts, because puppet apply does not read data from stdin):
#   json2dir_input  path of the document (the launcher passes /dev/stdin)
#   json2dir_cwd    absolute path of the target directory
#   json2dir_umask  the process umask in octal, as printed by `umask`
#
# Puppet regex literals turn `\\` into `\`, so backslash, slash and `"` are written \x5c, \x2f, \x22.

# Split the text into tokens: strings and the punctuation { } [ ] : ,
# Everything between tokens must be JSON whitespace; anything else (numbers, true, false,
# null, comments, unterminated strings, a byte order mark) is rejected here.
function json2dir::tokens(String $text) >> Array[String] {
  $parts = split($text, /(\x22[^\x22\x5c]*(?:\x5c[\s\S][^\x22\x5c]*)*\x22|[{}\[\]:,])/)
  $parts.each |$i, $p| {
    if $i % 2 == 0 and $p !~ /\A[ \t\n\r]*\z/ {
      fail("json2dir: invalid JSON: unexpected text ${String($p[0, 20], '%p')}")
    }
  }
  $parts.filter |$i, $p| { $i % 2 == 1 }
}

# Decode a JSON string token (with its quotes) into its value.
function json2dir::decode(String $tok) >> String {
  $body = $tok[1, $tok.length - 2]
  if $body =~ /[\x00-\x1f]/ {
    fail('json2dir: invalid JSON: control character in a string')
  }
  $simple = {
    '\\"' => 0x22, '\\\\' => 0x5c, '\\/' => 0x2f, '\\b' => 0x08,
    '\\f' => 0x0c, '\\n' => 0x0a, '\\r' => 0x0d, '\\t' => 0x09,
  }
  # Odd parts are escapes, even parts are literal text (which must contain no backslash).
  $parts = split($body, /(\x5cu[0-9a-fA-F]{4}|\x5c[\x22\x5c\x2fbfnrt])/)
  $r = $parts.reduce({ 'out' => '', 'hi' => -1, 'i' => 0 }) |$m, $p| {
    $i = $m['i'] + 1
    if $m['i'] % 2 == 0 {
      if $p =~ /\x5c/ { fail('json2dir: invalid JSON: bad escape in a string') }
      if $m['hi'] >= 0 and $p != '' { fail('json2dir: unpaired surrogate in a string') }
      $m + { 'out' => "${m['out']}${p}", 'i' => $i }
    } else {
      if $p =~ /\A\x5cu([0-9a-fA-F]{4})\z/ { $cp = Integer("0x${1}") } else { $cp = $simple[$p] }
      if $m['hi'] >= 0 {
        if $cp < 0xDC00 or $cp > 0xDFFF { fail('json2dir: unpaired surrogate in a string') }
        $c = sprintf('%c', 0x10000 + ($m['hi'] - 0xD800) * 1024 + ($cp - 0xDC00))
        $m + { 'out' => "${m['out']}${c}", 'hi' => -1, 'i' => $i }
      } elsif $cp >= 0xD800 and $cp <= 0xDBFF {
        $m + { 'hi' => $cp, 'i' => $i }
      } elsif $cp >= 0xDC00 and $cp <= 0xDFFF {
        fail('json2dir: unpaired surrogate in a string')
      } else {
        $m + { 'out' => "${m['out']}${sprintf('%c', $cp)}", 'i' => $i }
      }
    }
  }
  if $r['hi'] >= 0 { fail('json2dir: unpaired surrogate in a string') }
  $r['out']
}

# Parse the token list with an explicit stack (no recursion, so depth is not limited by the
# Ruby stack) and return the entries as [path, kind, payload], parents before children.
# Strings are compared with regexes or hash keys: Puppet's == and `in` ignore case.
function json2dir::entries(Array[String] $tokens, String $root) >> Array {
  $init = { 'st' => 'root', 'stack' => [], 'path' => '', 'kind' => '', 'out' => [] }
  $r = $tokens.reduce($init) |$m, $t| {
    $stack = $m['stack']
    $depth = $stack.length
    case $m['st'] {
      'root': {
        if $t != '{' { fail('json2dir: the root must be an object') }
        $m + { 'st' => 'key_or_end', 'stack' => [{ 'path' => $root, 'seen' => {} }] }
      }
      'key_or_end', 'key': {
        if $t == '}' and $m['st'] == 'key_or_end' {
          $rest = $stack[0, $depth - 1]
          $m + { 'st' => $rest.empty ? { true => 'done', default => 'comma_or_end' }, 'stack' => $rest }
        } elsif $t =~ /\A\x22/ {
          $name = json2dir::decode($t)
          if $name == '' or $name =~ /\A\.\.?\z/ or $name =~ /[\x2f\x00]/ {
            fail("json2dir: invalid name ${String($name, '%p')}")
          }
          $top = $stack[-1]
          if $top['seen'][$name] != undef { fail("json2dir: duplicate name ${String($name, '%p')}") }
          $newtop = $top + { 'seen' => $top['seen'] + { $name => true } }
          $m + { 'st' => 'colon', 'path' => "${top['path']}/${name}",
                 'stack' => $stack[0, $depth - 1] + [$newtop] }
        } else {
          fail('json2dir: invalid JSON: expected a member name')
        }
      }
      'colon': {
        if $t != ':' { fail("json2dir: invalid JSON: expected ':'") }
        $m + { 'st' => 'value' }
      }
      'value': {
        if $t == '{' {
          $m + { 'st' => 'key_or_end', 'out' => $m['out'] << [$m['path'], 'dir', ''],
                 'stack' => $stack + [{ 'path' => $m['path'], 'seen' => {} }] }
        } elsif $t == '[' {
          $m + { 'st' => 'a_kind' }
        } elsif $t =~ /\A\x22/ {
          $m + { 'st' => 'comma_or_end', 'out' => $m['out'] << [$m['path'], 'file', json2dir::decode($t)] }
        } else {
          fail('json2dir: invalid JSON: expected a value')
        }
      }
      'comma_or_end': {
        if $t == ',' {
          $m + { 'st' => 'key' }
        } elsif $t == '}' {
          $rest = $stack[0, $depth - 1]
          $m + { 'st' => $rest.empty ? { true => 'done', default => 'comma_or_end' }, 'stack' => $rest }
        } else {
          fail("json2dir: invalid JSON: expected ',' or '}'")
        }
      }
      'a_kind': {
        if $t !~ /\A\x22/ { fail('json2dir: an array must be ["link", target] or ["script", content]') }
        $kind = json2dir::decode($t)
        if $kind !~ /\A(link|script)\z/ { fail("json2dir: unknown array kind ${String($kind, '%p')}") }
        $m + { 'st' => 'a_comma', 'kind' => $kind }
      }
      'a_comma': {
        if $t != ',' { fail('json2dir: an array must have exactly two strings') }
        $m + { 'st' => 'a_payload' }
      }
      'a_payload': {
        if $t !~ /\A\x22/ { fail('json2dir: an array must have exactly two strings') }
        $m + { 'st' => 'a_end', 'out' => $m['out'] << [$m['path'], $m['kind'], json2dir::decode($t)] }
      }
      'a_end': {
        if $t != ']' { fail('json2dir: an array must have exactly two strings') }
        $m + { 'st' => 'comma_or_end' }
      }
      default: {
        fail('json2dir: invalid JSON: text after the root object')
      }
    }
  }
  if $r['st'] != 'done' { fail('json2dir: invalid JSON: unexpected end of input') }
  $r['out']
}

# --- main -------------------------------------------------------------------------------

$cwd = $facts['json2dir_cwd']
$umask = $facts['json2dir_umask']
unless $cwd =~ /\A\x2f/ { fail('json2dir: fact json2dir_cwd must be an absolute path') }
# File modes: 0666 & ~umask, and | 0111 for scripts (Puppet has no bitwise operators).
# They are written symbolically ("u=rw,g=r,o=r"): Puppet adds x to every r of a numeric mode
# when the path is (or is a symlink to) a directory at apply time, even if it replaces it.
$file_perm = { '0' => 'rw', '1' => 'rw', '2' => 'r', '3' => 'r', '4' => 'w', '5' => 'w', '6' => '', '7' => '' }
$exec_perm = { '0' => 'rwx', '1' => 'rwx', '2' => 'rx', '3' => 'rx', '4' => 'wx', '5' => 'wx', '6' => 'x', '7' => 'x' }
if $umask =~ /\A[0-7]*([0-7])([0-7])([0-7])\z/ {
  $file_mode = "u=${file_perm[$1]},g=${file_perm[$2]},o=${file_perm[$3]}"
  $exec_mode = "u=${exec_perm[$1]},g=${exec_perm[$2]},o=${exec_perm[$3]}"
} else {
  fail('json2dir: fact json2dir_umask must be octal')
}

# Converting Binary to String with %s fails unless the bytes are valid UTF-8
# (Ruby's check: no overlong forms, no encoded surrogates, nothing above U+10FFFF).
$text = String(binary_file($facts['json2dir_input']), '%s')
$entries = json2dir::entries(json2dir::tokens($text), $cwd)

$entries.each |$e| {
  $path = $e[0]
  case $e[1] {
    'dir': {
      # An existing directory is reused (its mode is not managed); a file or symlink in the
      # way is removed (links => manage: never followed).
      file { $path: ensure => directory, links => manage, backup => false, force => false }
    }
    'file', 'script': {
      # Binary content is written as is. A String content with a line like "{md5}..." would be
      # taken as a filebucket checksum, and puppet apply turns a plain Binary back into a String
      # (DeferredResolver), so the Binary is built by a Deferred call at apply time. The mode is always set, otherwise Puppet keeps the mode of a replaced file.
      # force => false: a directory in the way is not removed, and the resource fails.
      file { $path:
        ensure  => file,
        content => Deferred('new', [Binary, $e[2], '%s']),
        mode    => $e[1] ? { 'script' => $exec_mode, default => $file_mode },
        links   => manage,
        backup  => false,
        force   => false,
      }
    }
    'link': {
      # Puppet gives the target 'notlink' a special meaning and needs a non-newline character.
      if $e[2] =~ /\Anotlink\z/ or $e[2] !~ /./ {
        fail("json2dir: link target ${String($e[2], '%p')} cannot be expressed in Puppet")
      }
      file { $path: ensure => link, target => $e[2], links => manage, backup => false, force => false }
    }
    default: { fail('json2dir: internal error') }
  }
}
