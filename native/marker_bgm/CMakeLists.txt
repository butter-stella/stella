cmake_minimum_required(VERSION 3.20)

project(stella_marker_bgm LANGUAGES CXX)

include(FetchContent)
find_package(Python3 REQUIRED COMPONENTS Interpreter)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

set(STELLA_GODOT_CPP_COMMIT
	"58d1de720b8ffe9f8ffcdfe3a85148582cfd2e74"
	CACHE STRING "Exact godot-cpp commit for the Godot 4.6.1 ABI")
set(GODOTCPP_API_VERSION "4.6" CACHE STRING "" FORCE)
if(NOT DEFINED GODOTCPP_TARGET)
	set(GODOTCPP_TARGET "template_debug" CACHE STRING "")
endif()
set(GODOTCPP_DISABLE_EXCEPTIONS ON CACHE BOOL "" FORCE)
set(GODOTCPP_ENABLE_TESTING OFF CACHE BOOL "" FORCE)
set(GODOTCPP_SYSTEM_HEADERS ON CACHE BOOL "" FORCE)

FetchContent_Declare(
	godot_cpp
	GIT_REPOSITORY https://github.com/godotengine/godot-cpp.git
	GIT_TAG ${STELLA_GODOT_CPP_COMMIT}
	GIT_SHALLOW FALSE
)
FetchContent_MakeAvailable(godot_cpp)

add_library(stella_marker_bgm_stb OBJECT
	third_party/stb/stb_vorbis_impl.cpp
)
target_compile_features(stella_marker_bgm_stb PRIVATE cxx_std_17)
target_include_directories(stella_marker_bgm_stb PRIVATE
	${CMAKE_CURRENT_SOURCE_DIR}/third_party/stb
)
set_target_properties(stella_marker_bgm_stb PROPERTIES
	POSITION_INDEPENDENT_CODE ON
)

add_library(stella_marker_bgm SHARED
	src/register_types.cpp
	src/stella_marker_bgm.cpp
	$<TARGET_OBJECTS:stella_marker_bgm_stb>
)
target_compile_features(stella_marker_bgm PRIVATE cxx_std_17)
target_include_directories(stella_marker_bgm PRIVATE
	${CMAKE_CURRENT_SOURCE_DIR}/src
	${CMAKE_CURRENT_SOURCE_DIR}/third_party/stb
)
target_link_libraries(stella_marker_bgm PRIVATE godot::cpp)

if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
	set(STELLA_PLATFORM "macos")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
	set(STELLA_PLATFORM "linux")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Windows")
	set(STELLA_PLATFORM "windows")
else()
	message(FATAL_ERROR "Unsupported Stella marker BGM platform: ${CMAKE_SYSTEM_NAME}")
endif()

if(DEFINED STELLA_BUILD_ARCH)
	if(NOT STELLA_BUILD_ARCH MATCHES "^(universal|arm64|x86_64)$")
		message(FATAL_ERROR "Unsupported explicit Stella build architecture: ${STELLA_BUILD_ARCH}")
	endif()
	set(STELLA_ARCH "${STELLA_BUILD_ARCH}")
else()
	string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" STELLA_PROCESSOR)
	if(STELLA_PROCESSOR MATCHES "^(aarch64|arm64)$")
		set(STELLA_ARCH "arm64")
	elseif(STELLA_PROCESSOR MATCHES "^(x86_64|amd64)$")
		set(STELLA_ARCH "x86_64")
	else()
		message(FATAL_ERROR "Unsupported Stella marker BGM architecture: ${CMAKE_SYSTEM_PROCESSOR}")
	endif()
endif()

set(STELLA_NATIVE_OUTPUT
	${CMAKE_CURRENT_SOURCE_DIR}/../../addons/stella/native/bin)
set_target_properties(stella_marker_bgm PROPERTIES
	CXX_VISIBILITY_PRESET hidden
	VISIBILITY_INLINES_HIDDEN YES
	LIBRARY_OUTPUT_DIRECTORY ${STELLA_NATIVE_OUTPUT}
	RUNTIME_OUTPUT_DIRECTORY ${STELLA_NATIVE_OUTPUT}
	LIBRARY_OUTPUT_DIRECTORY_DEBUG ${STELLA_NATIVE_OUTPUT}
	LIBRARY_OUTPUT_DIRECTORY_RELEASE ${STELLA_NATIVE_OUTPUT}
	RUNTIME_OUTPUT_DIRECTORY_DEBUG ${STELLA_NATIVE_OUTPUT}
	RUNTIME_OUTPUT_DIRECTORY_RELEASE ${STELLA_NATIVE_OUTPUT}
	OUTPUT_NAME "stella_marker_bgm.${STELLA_PLATFORM}.${GODOTCPP_TARGET}.${STELLA_ARCH}"
)

if(MSVC)
	target_compile_options(stella_marker_bgm_stb PRIVATE
		/W4 /WX
		# Pinned stb intentionally narrows integer fields and shadows locals.
		# These exemptions apply only to its isolated implementation object.
		/wd4244
		/wd4245
		/wd4456
		/wd4457
		/wd4701
	)
	target_compile_options(stella_marker_bgm PRIVATE /W4 /WX)
else()
	target_compile_options(stella_marker_bgm_stb PRIVATE
		-Wall -Wextra -Werror
		# These diagnostics arise only while compiling the pinned stb
		# implementation object, never a Stella translation unit.
		-Wno-unused-function
		-Wno-unused-parameter
	)
	if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
		target_compile_options(stella_marker_bgm_stb PRIVATE
			# GCC release inlining cannot prove that stb_vorbis' bounded
			# memory reader initializes its page-header scratch first.
			-Wno-maybe-uninitialized
		)
	endif()
	target_compile_options(stella_marker_bgm PRIVATE
		-Wall -Wextra -Werror
	)
endif()

add_custom_target(stella_marker_bgm_compile_gate ALL
	COMMAND
		${Python3_EXECUTABLE}
		${CMAKE_CURRENT_SOURCE_DIR}/../../tests/check_marker_bgm_compile_commands.py
		${CMAKE_BINARY_DIR}/compile_commands.json
		${CMAKE_CXX_COMPILER_ID}
	DEPENDS stella_marker_bgm
	VERBATIM
)
