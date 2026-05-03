cmake_minimum_required(VERSION 3.22.1)
project(drawing CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(drawing SHARED
    renderer.cpp
)

find_library(log-lib log)

target_link_libraries(drawing PRIVATE
    GLESv3
    EGL
    android
    jnigraphics      # AndroidBitmap_lockPixels for thumbnail readback
    ${log-lib}
)

target_compile_options(drawing PRIVATE
    -Wall
    -Wextra
    -Wno-unused-parameter
)
