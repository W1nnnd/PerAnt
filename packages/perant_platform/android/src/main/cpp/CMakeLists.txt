# SPDX-License-Identifier: GPL-3.0-only
cmake_minimum_required(VERSION 3.22.1)
project(perant_pty LANGUAGES C)
add_library(perant_pty SHARED perant_pty.c)
target_compile_features(perant_pty PRIVATE c_std_11)
target_compile_options(perant_pty PRIVATE -Wall -Wextra -Werror -Wno-unused-parameter)
target_link_options(perant_pty PRIVATE "-Wl,-z,max-page-size=16384")
