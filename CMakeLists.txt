cmake_minimum_required(VERSION 3.20)
project(DraftingTable LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(drafting_table_core STATIC
    core/src/DTCore.cpp
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
endif()
