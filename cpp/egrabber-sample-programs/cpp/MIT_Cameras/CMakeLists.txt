cmake_minimum_required(VERSION 3.8)
project(MIT_Cameras)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_CXX_STANDARD 11)

# Each .cpp is a standalone program
file(GLOB sources "${CMAKE_SOURCE_DIR}/*.cpp")

foreach(source ${sources})
    get_filename_component(name ${source} NAME_WE)
    add_executable(${name} ${source})
    target_include_directories(${name} PUBLIC "/opt/euresys/egrabber/include")
    target_link_libraries(${name} dl pthread)
endforeach()
