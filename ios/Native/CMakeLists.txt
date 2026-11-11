cmake_minimum_required(VERSION 3.22)
project(SmoothPlayerNAS LANGUAGES C)
set(CMAKE_C_STANDARD 11)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(ENABLE_EXAMPLES OFF CACHE BOOL "" FORCE)
set(ENABLE_GSSAPI OFF CACHE BOOL "" FORCE)
set(ENABLE_LIBKRB5 OFF CACHE BOOL "" FORCE)
find_package(Python3 REQUIRED COMPONENTS Interpreter)
execute_process(COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_CURRENT_LIST_DIR}/../../third_party/scripts/prepare_libsmb2.py"
    "${CMAKE_CURRENT_LIST_DIR}/../../third_party/src/libsmb2-libsmb2-6.2"
    COMMAND_ERROR_IS_FATAL ANY)
add_subdirectory(${CMAKE_CURRENT_LIST_DIR}/../../third_party/src/libsmb2-libsmb2-6.2 ${CMAKE_CURRENT_BINARY_DIR}/smb2)
add_library(SmoothPlayerNAS STATIC src/SmoothPlayerNAS.c)
target_include_directories(SmoothPlayerNAS PUBLIC include PRIVATE ../../third_party/src/libsmb2-libsmb2-6.2/include)
target_compile_options(SmoothPlayerNAS PRIVATE -Wall -Wextra -Wno-deprecated-declarations)
target_link_libraries(SmoothPlayerNAS PRIVATE smb2 "-framework CFNetwork" "-framework CoreFoundation")
