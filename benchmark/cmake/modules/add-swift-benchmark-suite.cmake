
include(CMakeParseArguments)


# Run a shell command and assign output to a variable or fail with an error.
# Example usage:
#   runcmd(COMMAND "xcode-select" "-p"
#          VARIABLE xcodepath
#          ERROR "Unable to find current Xcode path")
function(runcmd)
  cmake_parse_arguments(RUNCMD "" "VARIABLE;ERROR" "COMMAND" ${ARGN})
  execute_process(
      COMMAND ${RUNCMD_COMMAND}
      OUTPUT_VARIABLE ${RUNCMD_VARIABLE}
      RESULT_VARIABLE result
      ERROR_QUIET OUTPUT_STRIP_TRAILING_WHITESPACE)
  if(NOT "${result}" MATCHES "0")
    message(FATAL_ERROR "${RUNCMD_ERROR}")
  endif()
  set(${RUNCMD_VARIABLE} ${${RUNCMD_VARIABLE}} PARENT_SCOPE)
endfunction(runcmd)


function(swift_benchmark_compile)
  cmake_parse_arguments(SWIFT_BENCHMARK_COMPILE "" "PLATFORM" "" ${ARGN})
  if(IS_SWIFT_BUILD)
    set(stdlib_dependencies "swift"
      ${UNIVERSAL_LIBRARY_NAMES_${SWIFT_BENCHMARK_COMPILE_PLATFORM}})
  endif()

  add_custom_target("copy-swift-stdlib-${SWIFT_BENCHMARK_COMPILE_PLATFORM}"
      DEPENDS ${stdlib_dependencies}
      COMMAND
        "${CMAKE_COMMAND}" "-E" "copy_directory"
        "${SWIFT_LIBRARY_PATH}/${SWIFT_BENCHMARK_COMPILE_PLATFORM}"
        "${libswiftdir}/${SWIFT_BENCHMARK_COMPILE_PLATFORM}")

  add_custom_target("adhoc-sign-swift-stdlib-${SWIFT_BENCHMARK_COMPILE_PLATFORM}"
      DEPENDS "copy-swift-stdlib-${SWIFT_BENCHMARK_COMPILE_PLATFORM}"
      COMMAND
        "codesign" "-f" "-s" "-"
        "${libswiftdir}/${SWIFT_BENCHMARK_COMPILE_PLATFORM}/*.dylib" "2>/dev/null")

  set(platform_executables)
  foreach(arch ${${SWIFT_BENCHMARK_COMPILE_PLATFORM}_arch})
    foreach(optset ${SWIFT_OPTIMIZATION_LEVELS})
      set(sdk ${${SWIFT_BENCHMARK_COMPILE_PLATFORM}_sdk})
      set(ver ${${SWIFT_BENCHMARK_COMPILE_PLATFORM}_ver})
      set(triple_platform ${${SWIFT_BENCHMARK_COMPILE_PLATFORM}_triple_platform})

      set(target "${arch}-apple-${triple_platform}${ver}")

      set(objdir "${CMAKE_CURRENT_BINARY_DIR}/${optset}-${target}")
      file(MAKE_DIRECTORY "${objdir}")

      string(REGEX REPLACE "_.*" "" optflag "${optset}")
      string(REGEX REPLACE "^[^_]+" "" opt_suffix "${optset}")

      set(benchvar "BENCHOPTS${opt_suffix}")
      if (NOT DEFINED ${benchvar})
        message(FATAL_ERROR "Invalid benchmark configuration ${optset}")
      endif()

      set(bench_flags "${${benchvar}}")

      set(common_options
          "-c"
          "-sdk" "${sdk}"
          "-target" "${target}"
          "-F" "${sdk}/../../../Developer/Library/Frameworks"
          "-${optset}"
          "-D" "INTERNAL_CHECKS_ENABLED"
          "-D" "SWIFT_ENABLE_OBJECT_LITERALS"
          "-no-link-objc-runtime")

      # Always optimize the driver modules.
      # Note that we compile the driver for Ounchecked also with -Ounchecked
      # (and not with -O), because of <rdar://problem/19614516>.
      string(REPLACE "Onone" "O" driver_opt "${optflag}")

      set(common_options_driver
          "-c"
          "-sdk" "${sdk}"
          "-target" "${target}"
          "-F" "${sdk}/../../../Developer/Library/Frameworks"
          "-${driver_opt}"
          "-D" "INTERNAL_CHECKS_ENABLED"
          "-D" "SWIFT_ENABLE_OBJECT_LITERALS"
          "-no-link-objc-runtime")

      set(bench_library_objects)
      set(bench_library_sibfiles)
      foreach(module_name ${BENCH_DRIVER_LIBRARY_MODULES})
        if("${module_name}" STREQUAL "DriverUtils")
          set(extra_sources "${srcdir}/utils/ArgParse.swift")
        endif()

        set(objfile "${objdir}/${module_name}.o")
        set(swiftmodule "${objdir}/${module_name}.swiftmodule")
        list(APPEND bench_library_objects "${objfile}")
        set(source "${srcdir}/utils/${module_name}.swift")
        add_custom_command(
            OUTPUT "${objfile}"
            DEPENDS ${stdlib_dependencies} "${source}" ${extra_sources}
            COMMAND "${SWIFT_EXEC}"
            ${common_options_driver}
            ${BENCH_DRIVER_LIBRARY_FLAGS}
            "-force-single-frontend-invocation"
            "-parse-as-library"
            "-module-name" "${module_name}"
            "-emit-module" "-emit-module-path" "${swiftmodule}"
            "-o" "${objfile}"
            "${source}" ${extra_sources})
        if(SWIFT_BENCHMARK_EMIT_SIB)
          set(sibfile "${objdir}/${module_name}.sib")
          list(APPEND bench_library_sibfiles "${sibfile}")
          add_custom_command(
              OUTPUT "${sibfile}"
              DEPENDS
                ${stdlib_dependencies} "${srcdir}/utils/${module_name}.swift"
                ${extra_sources}
              COMMAND "${SWIFT_EXEC}"
              ${common_options_driver}
              ${BENCH_DRIVER_LIBRARY_FLAGS}
              "-force-single-frontend-invocation"
              "-parse-as-library"
              "-module-name" "${module_name}"
              "-emit-sib"
              "-o" "${sibfile}"
              "${srcdir}/utils/${module_name}.swift" ${extra_sources})
        endif()
      endforeach()

      foreach(module_name ${BENCH_LIBRARY_MODULES})
        set(objfile "${objdir}/${module_name}.o")
        set(swiftmodule "${objdir}/${module_name}.swiftmodule")
        list(APPEND bench_library_objects "${objfile}")
        add_custom_command(
            OUTPUT "${objfile}"
            DEPENDS
              ${stdlib_dependencies} "${srcdir}/utils/${module_name}.swift"
              ${extra_sources}
            COMMAND "${SWIFT_EXEC}"
            ${common_options}
            "-force-single-frontend-invocation"
            "-parse-as-library"
            "-module-name" "${module_name}"
            "-emit-module" "-emit-module-path" "${swiftmodule}"
            "-o" "${objfile}"
            "${srcdir}/utils/${module_name}.swift" ${extra_sources})
        if (SWIFT_BENCHMARK_EMIT_SIB)
          set(sibfile "${objdir}/${module_name}.sib")
          list(APPEND bench_library_sibfiles "${sibfile}")
          add_custom_command(
              OUTPUT "${sibfile}"
              DEPENDS
                ${stdlib_dependencies} "${srcdir}/utils/${module_name}.swift"
                ${extra_sources}
              COMMAND "${SWIFT_EXEC}"
              ${common_options}
              "-force-single-frontend-invocation"
              "-parse-as-library"
              "-module-name" "${module_name}"
              "-emit-sib"
              "-o" "${sibfile}"
              "${srcdir}/utils/${module_name}.swift" ${extra_sources})
        endif()
      endforeach()

      set(SWIFT_BENCH_OBJFILES)
      set(SWIFT_BENCH_SIBFILES)
      foreach(module_name ${SWIFT_BENCH_MODULES})
        if(module_name)
          set(objfile "${objdir}/${module_name}.o")
          set(swiftmodule "${objdir}/${module_name}.swiftmodule")
          list(APPEND SWIFT_BENCH_OBJFILES "${objfile}")
          add_custom_command(
              OUTPUT "${objfile}"
              DEPENDS
                ${stdlib_dependencies} ${bench_library_objects}
                "${srcdir}/single-source/${module_name}.swift"
              COMMAND "${SWIFT_EXEC}"
              ${common_options}
              "-parse-as-library"
              ${bench_flags}
              "-module-name" "${module_name}"
              "-emit-module" "-emit-module-path" "${swiftmodule}"
              "-I" "${objdir}"
              "-o" "${objfile}"
              "${srcdir}/single-source/${module_name}.swift")
          if (SWIFT_BENCHMARK_EMIT_SIB)
            set(sibfile "${objdir}/${module_name}.sib")
            list(APPEND SWIFT_BENCH_SIBFILES "${sibfile}")
            add_custom_command(
                OUTPUT "${sibfile}"
                DEPENDS
                  ${stdlib_dependencies} ${bench_library_sibfiles}
                  "${srcdir}/single-source/${module_name}.swift"
                COMMAND "${SWIFT_EXEC}"
                ${common_options}
                "-parse-as-library"
                ${bench_flags}
                "-module-name" "${module_name}"
                "-I" "${objdir}"
                "-emit-sib"
                "-o" "${sibfile}"
                "${srcdir}/single-source/${module_name}.swift")
          endif()
        endif()
      endforeach()

      foreach(module_name ${SWIFT_MULTISOURCE_BENCHES})
        if ("${bench_flags}" MATCHES "-whole-module.*" AND
            NOT "${bench_flags}" MATCHES "-num-threads.*")
          # Regular whole-module-compilation: only a single object file is
          # generated.
          set(objfile "${objdir}/${module_name}.o")
          list(APPEND SWIFT_BENCH_OBJFILES "${objfile}")
          set(sources)
          foreach(source ${${module_name}_sources})
            list(APPEND sources "${srcdir}/multi-source/${source}")
          endforeach()
          add_custom_command(
              OUTPUT "${objfile}"
              DEPENDS
                ${stdlib_dependencies} ${bench_library_objects} ${sources}
              COMMAND "${SWIFT_EXEC}"
              ${common_options}
              ${bench_flags}
              "-parse-as-library"
              "-emit-module" "-module-name" "${module_name}"
              "-I" "${objdir}"
              "-o" "${objfile}"
              ${sources})
        else()

          # No whole-module-compilation or multi-threaded compilation.
          # There is an output object file for each input file. We have to write
          # an output-map-file to specify the output object file names.
          set(sources)
          set(objfiles)
          set(json "{\n")
          foreach(source ${${module_name}_sources})
              list(APPEND sources "${srcdir}/multi-source/${source}")

              get_filename_component(basename "${source}" NAME_WE)
              set(objfile "${objdir}/${module_name}/${basename}.o")

              string(CONCAT json "${json}"
    "  \"${srcdir}/multi-source/${source}\": { \"object\": \"${objfile}\" },\n")

              list(APPEND objfiles "${objfile}")
              list(APPEND SWIFT_BENCH_OBJFILES "${objfile}")
          endforeach()
          string(CONCAT json "${json}" "}")
          file(WRITE "${objdir}/${module_name}/outputmap.json" ${json})

          add_custom_command(
              OUTPUT ${objfiles}
              DEPENDS
                ${stdlib_dependencies} ${bench_library_objects} ${sources}
              COMMAND "${SWIFT_EXEC}"
              ${common_options}
              ${bench_flags}
              "-parse-as-library"
              "-module-name" "${module_name}"
              "-I" "${objdir}"
              "-output-file-map" "${objdir}/${module_name}/outputmap.json"
              ${sources})
        endif()
      endforeach()

      set(module_name "main")
      set(source "${srcdir}/utils/${module_name}.swift")
      add_custom_command(
          OUTPUT "${objdir}/${module_name}.o"
          DEPENDS
            ${stdlib_dependencies}
            ${bench_library_objects} ${SWIFT_BENCH_OBJFILES}
            ${bench_library_sibfiles} ${SWIFT_BENCH_SIBFILES} "${source}"
          COMMAND "${SWIFT_EXEC}"
          ${common_options}
          "-force-single-frontend-invocation"
          "-emit-module" "-module-name" "${module_name}"
          "-I" "${objdir}"
          "-o" "${objdir}/${module_name}.o"
          "${source}")
      list(APPEND SWIFT_BENCH_OBJFILES "${objdir}/${module_name}.o")

      if("${SWIFT_BENCHMARK_COMPILE_PLATFORM}" STREQUAL "macosx")
        set(OUTPUT_EXEC "${bindir}/Benchmark_${optset}")
      else()
        set(OUTPUT_EXEC "${bindir}/Benchmark_${optset}-${target}")
      endif()

      add_custom_command(
          OUTPUT "${OUTPUT_EXEC}"
          DEPENDS
            ${bench_library_objects} ${SWIFT_BENCH_OBJFILES}
            "adhoc-sign-swift-stdlib-${SWIFT_BENCHMARK_COMPILE_PLATFORM}"
          COMMAND
            "${CLANG_EXEC}"
            "-fno-stack-protector"
            "-fPIC"
            "-Werror=date-time"
            "-fcolor-diagnostics"
            "-O3"
            "-Wl,-search_paths_first"
            "-Wl,-headerpad_max_install_names"
            "-target" "${target}"
            "-isysroot" "${sdk}"
            "-arch" "${arch}"
            "-F" "${sdk}/../../../Developer/Library/Frameworks"
            "-m${triple_platform}-version-min=${ver}"
            "-lobjc"
            "-L${SWIFT_LIBRARY_PATH}/${SWIFT_BENCHMARK_COMPILE_PLATFORM}"
            "-Xlinker" "-rpath"
            "-Xlinker" "@executable_path/../lib/swift/${SWIFT_BENCHMARK_COMPILE_PLATFORM}"
            ${bench_library_objects}
            ${SWIFT_BENCH_OBJFILES}
            "-o" "${OUTPUT_EXEC}"
          COMMAND
            "codesign" "-f" "-s" "-" "${OUTPUT_EXEC}")

      list(APPEND platform_executables "${OUTPUT_EXEC}")
    endforeach()

    set(executable_target "swift-benchmark-${SWIFT_BENCHMARK_COMPILE_PLATFORM}-${arch}")

    add_custom_target("${executable_target}"
        DEPENDS ${platform_executables})

    if(IS_SWIFT_BUILD AND "${SWIFT_BENCHMARK_COMPILE_PLATFORM}" STREQUAL "macosx")
      add_custom_command(
          TARGET "${executable_target}"
          POST_BUILD
          COMMAND
            "mv" ${platform_executables} "${SWIFT_RUNTIME_OUTPUT_INTDIR}")

      add_custom_target("check-${executable_target}"
          COMMAND "${SWIFT_RUNTIME_OUTPUT_INTDIR}/Benchmark_Driver" "run"
                  "-o" "O" "--output-dir" "${CMAKE_CURRENT_BINARY_DIR}/logs"
                  "--swift-repo" "${SWIFT_SOURCE_DIR}"
                  "--iterations" "3"
          COMMAND "${SWIFT_RUNTIME_OUTPUT_INTDIR}/Benchmark_Driver" "run"
                  "-o" "Onone" "--output-dir" "${CMAKE_CURRENT_BINARY_DIR}/logs"
                  "--swift-repo" "${SWIFT_SOURCE_DIR}"
                  "--iterations" "3"
          COMMAND "${SWIFT_RUNTIME_OUTPUT_INTDIR}/Benchmark_Driver" "compare"
                  "--log-dir" "${CMAKE_CURRENT_BINARY_DIR}/logs"
                  "--swift-repo" "${SWIFT_SOURCE_DIR}"
                  "--compare-script"
                  "${SWIFT_SOURCE_DIR}/benchmark/scripts/compare_perf_tests.py")
    endif()
  endforeach()
endfunction()
