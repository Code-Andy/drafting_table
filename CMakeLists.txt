cmake_minimum_required(VERSION 3.20)
project(DraftingTable LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(drafting_table_core STATIC
    core/src/DTCore.cpp
    core/src/DTDocument.cpp
    core/src/DTPersistence.cpp
)
target_include_directories(drafting_table_core
    PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/core/include
)
target_compile_features(drafting_table_core PUBLIC cxx_std_20)

if (MSVC)
    target_compile_options(drafting_table_core PRIVATE /W4 /permissive-)
else()
    target_compile_options(drafting_table_core PRIVATE -Wall -Wextra -Wpedantic)
endif()

add_library(drafting_table_renderer_common STATIC
    renderer/common/BrushEmitter.cpp
    renderer/common/Coverage.cpp
)
target_include_directories(drafting_table_renderer_common
    PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/renderer/common
)
target_link_libraries(drafting_table_renderer_common PUBLIC drafting_table_core)
target_compile_features(drafting_table_renderer_common PUBLIC cxx_std_20)
if (MSVC)
    target_compile_options(drafting_table_renderer_common PRIVATE /W4 /permissive-)
else()
    target_compile_options(drafting_table_renderer_common PRIVATE -Wall -Wextra -Wpedantic)
endif()
include(CTest)
if (BUILD_TESTING)
    add_executable(drafting_table_core_tests
        tests/core/test_core.cpp
    )
    target_link_libraries(drafting_table_core_tests PRIVATE drafting_table_core)
    target_compile_features(drafting_table_core_tests PRIVATE cxx_std_20)
    if (MSVC)
        target_compile_options(drafting_table_core_tests PRIVATE /W4 /permissive-)
    else()
        target_compile_options(drafting_table_core_tests PRIVATE -Wall -Wextra -Wpedantic)
    endif()
    add_test(NAME drafting_table_core_tests COMMAND drafting_table_core_tests)

    add_executable(drafting_table_document_tests
        tests/core/test_document.cpp
    )
    target_link_libraries(drafting_table_document_tests PRIVATE drafting_table_core)
    target_compile_features(drafting_table_document_tests PRIVATE cxx_std_20)

    add_executable(drafting_table_brush_tests
        tests/core/test_brush.cpp
    )
    target_link_libraries(drafting_table_brush_tests
        PRIVATE drafting_table_renderer_common
    )
    target_compile_features(drafting_table_brush_tests PRIVATE cxx_std_20)

    add_executable(drafting_table_metal_layout_tests
        tests/core/test_metal_layout.cpp
    )
    target_include_directories(drafting_table_metal_layout_tests
        PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/renderer/metal
    )
    target_link_libraries(drafting_table_metal_layout_tests PRIVATE drafting_table_core)
    target_compile_features(drafting_table_metal_layout_tests PRIVATE cxx_std_20)

    foreach(test_target drafting_table_document_tests drafting_table_brush_tests drafting_table_metal_layout_tests)
        if (MSVC)
            target_compile_options(${test_target} PRIVATE /W4 /permissive-)
        else()
            target_compile_options(${test_target} PRIVATE -Wall -Wextra -Wpedantic)
        endif()
    endforeach()

    add_test(NAME drafting_table_document_tests COMMAND drafting_table_document_tests)
    add_test(NAME drafting_table_brush_tests COMMAND drafting_table_brush_tests)
    add_test(NAME drafting_table_metal_layout_tests COMMAND drafting_table_metal_layout_tests)
endif()
