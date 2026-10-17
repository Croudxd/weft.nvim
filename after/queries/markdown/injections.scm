; extends

; Some models emit language tags with a trailing slash (e.g. ```yaml/).
; Keep the transcript intact while resolving the actual parser name.
((fenced_code_block
  (info_string (language) @injection.language)
  (code_fence_content) @injection.content)
  (#match? @injection.language "/+$")
  (#gsub! @injection.language "/+$" ""))
