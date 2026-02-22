# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "fl_training_plugin")
project(${PROJECT_NAME} LANGUAGES CXX)

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "fl_training_plugin_plugin")

# Any new source files that you add to the plugin should be added here.
list(APPEND PLUGIN_SOURCES
  "fl_training_plugin.cpp"
)

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  ${PLUGIN_SOURCES}
)

# Apply standard settings
apply_standard_settings(${PLUGIN_NAME})

# Include directories
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. This should not be exported implicitly.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)

# Link Flutter libraries
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# ONNX Runtime Configuration
# User must download ORT Training package and extract to 'third_party/onnxruntime'
set(ORT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/third_party/onnxruntime")

if(EXISTS "${ORT_ROOT}")
  message(STATUS "Found ONNX Runtime at ${ORT_ROOT}")
  
  target_include_directories(${PLUGIN_NAME} PRIVATE
    "${ORT_ROOT}/include"
  )
  
  target_link_libraries(${PLUGIN_NAME} PRIVATE
    "${ORT_ROOT}/lib/onnxruntime.lib"
  )
  
  # Copy DLLs to output directory for runtime execution
  add_custom_command(TARGET ${PLUGIN_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${ORT_ROOT}/lib/onnxruntime.dll"
    "$<TARGET_FILE_DIR:${PLUGIN_NAME}>"
  )
else()
  message(WARNING "ONNX Runtime not found at ${ORT_ROOT}. Please run setup_fl_dependencies.ps1")
endif()


target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# List of absolute paths to libraries that should be bundled with the plugin.
set(fl_training_plugin_bundled_libraries
  ""
  PARENT_SCOPE
)
