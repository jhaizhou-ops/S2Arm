# NativeAOT writes one unquoted library path or linker flag per UTF-8 line.
# Do not tokenize whitespace: spaces belong to the library filename.
function(s2a_read_native_link_inputs filename output)
    file(STRINGS "${filename}" entries ENCODING UTF-8)
    set("${output}" "${entries}" PARENT_SCOPE)
endfunction()
