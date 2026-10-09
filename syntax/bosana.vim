if exists('b:current_syntax')
  finish
endif

" Keep native IDs in the buffer for editing, but hide the prefix and separator.
syntax match BosanaId /^\/[$@]\d\+ / conceal
syntax match BosanaSession /^\/\$\d\+ \zs.*$/
syntax match BosanaSession /^\%([ \t]\|\/[$@]\)\@!\S.*$/

highlight default link BosanaSession Title
let b:current_syntax = 'bosana'
