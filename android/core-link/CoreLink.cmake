# A game target requires the real native provider and the static service composition.
# Selecting this target is a build decision, never proof of successful game execution.
set(S2A_ANDROID_NATIVE_MODE "diagnostic" CACHE STRING "Native provider role: diagnostic or game")
set_property(CACHE S2A_ANDROID_NATIVE_MODE PROPERTY STRINGS diagnostic game)
if(NOT S2A_ANDROID_NATIVE_MODE STREQUAL "diagnostic" AND NOT S2A_ANDROID_NATIVE_MODE STREQUAL "game")
    message(FATAL_ERROR "S2A_ANDROID_NATIVE_MODE must be diagnostic or game")
endif()
if(S2A_ANDROID_NATIVE_MODE STREQUAL "game")
    # 真实游戏路径仍要求静态服务层；S2A_ANDROID_LINK_PROBE 只给显式链接探针用（main 的诊断入口）。
    if(NOT ANDROID OR (NOT S2A_CS_SERVICES STREQUAL "static" AND NOT S2A_ANDROID_LINK_PROBE))
        message(FATAL_ERROR "Android game mode requires ANDROID and S2A_CS_SERVICES=static (or a link probe)")
    endif()
endif()

set(S2A_ANDROID_CORE_LINK_DIR "${CMAKE_CURRENT_LIST_DIR}")

function(s2a_audit_diagnostic_core_link target archive consumer_root link_inputs)
    set(provider_role "diagnostic")
    if(ARGC GREATER 4)
        set(provider_role "${ARGV4}")
    endif()
    find_package(Python3 REQUIRED COMPONENTS Interpreter)
    set(source_list "${CMAKE_CURRENT_BINARY_DIR}/core-link-$<CONFIG>.sources")
    file(GENERATE OUTPUT "${source_list}"
        CONTENT "$<JOIN:$<TARGET_PROPERTY:${target},SOURCES>,\n>\n")
    file(GLOB_RECURSE consumers CONFIGURE_DEPENDS "${consumer_root}/*.cs")
    set_property(TARGET ${target} APPEND PROPERTY LINK_DEPENDS
        "${S2A_ANDROID_CORE_LINK_DIR}/audit.py" "${archive}" "${link_inputs}" ${consumers})
    add_custom_command(TARGET ${target} POST_BUILD
        COMMAND "${Python3_EXECUTABLE}" "${S2A_ANDROID_CORE_LINK_DIR}/audit.py"
            --provider-role "${provider_role}" --archive "${archive}" --library "$<TARGET_FILE:${target}>"
            --source-list "${source_list}" --source-root "${CMAKE_CURRENT_SOURCE_DIR}"
            --consumer-root "${consumer_root}" --android-elf
            --link-input-list "${link_inputs}" --readelf "${CMAKE_READELF}"
            --nm "${CMAKE_NM}"
            --report "${CMAKE_CURRENT_BINARY_DIR}/core-link-$<CONFIG>.json"
        VERBATIM COMMENT "Audit ${provider_role} NativeAOT providers (not game readiness)")
endfunction()
