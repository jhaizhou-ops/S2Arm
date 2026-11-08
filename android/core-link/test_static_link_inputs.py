#!/usr/bin/env python3
"""Exercise the production CMake reader, including an actual host static-library link."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

CMAKE = "cmake"
HELPER = Path(__file__).with_name("StaticLinkInputs.cmake")


class LinkInputTests(unittest.TestCase):
    def run_command(self, args):
        result = subprocess.run([str(x) for x in args], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def check_records(self, entries, newline="\n"):
        with tempfile.TemporaryDirectory(prefix="s2a-link-input-") as work:
            root = Path(work)
            source, output, script = root / "native inputs.txt", root / "actual.txt", root / "read.cmake"
            source.write_bytes((newline.join(entries) + newline).encode("utf-8"))
            script.write_text(
                'include("${HELPER}")\n'
                's2a_read_native_link_inputs("${INPUT}" actual)\n'
                'file(WRITE "${OUTPUT}" "")\n'
                'foreach(entry IN LISTS actual)\n'
                '  file(APPEND "${OUTPUT}" "${entry}\\n")\n'
                'endforeach()\n', encoding="utf-8"
            )
            self.run_command([CMAKE, f"-DHELPER={HELPER}", f"-DINPUT={source}",
                              f"-DOUTPUT={output}", "-P", script])
            self.assertEqual(output.read_text(encoding="utf-8").splitlines(), entries)

    def test_ascii_path_and_system_library(self):
        self.check_records(["/synthetic/runtime/libRuntime.a", "-lm"])

    def test_space_is_part_of_filename(self):
        self.check_records(["/synthetic/work space/lib runtime.a", "-ldl"])

    def test_utf8_path_is_one_record(self):
        self.check_records(["/synthetic/中文 目录/lib运行时.a", "-lm"])

    def test_crlf_preserves_utf8_paths_and_flags(self):
        self.check_records(["/synthetic/中文/libRuntime.a",
                            "/synthetic/other space/libSystem.a", "-ldl"], "\r\n")

    @unittest.skipUnless(shutil.which("cc") and shutil.which("make"), "host C compiler/make unavailable")
    def test_real_static_archive_in_utf8_directory_links(self):
        with tempfile.TemporaryDirectory(prefix="s2a-native-link-") as work:
            root = Path(work)
            producer = root / "producer"
            producer.mkdir()
            output_dir = root / "native assets 中文"
            (producer / "value.c").write_text("int fixture_value(void) { return 42; }\n")
            (producer / "CMakeLists.txt").write_text(
                'cmake_minimum_required(VERSION 3.16)\nproject(producer C)\n'
                'add_library(fixture STATIC value.c)\n'
                'set_target_properties(fixture PROPERTIES ARCHIVE_OUTPUT_DIRECTORY "${ARCHIVE_DIR}")\n'
                'file(GENERATE OUTPUT "${CMAKE_BINARY_DIR}/archive-path.txt" CONTENT "$<TARGET_FILE:fixture>\\n")\n',
                encoding="utf-8"
            )
            producer_build = root / "producer-build"
            self.run_command([CMAKE, "-S", producer, "-B", producer_build, "-G", "Unix Makefiles",
                              f"-DARCHIVE_DIR={output_dir}"])
            self.run_command([CMAKE, "--build", producer_build])
            archive = Path((producer_build / "archive-path.txt").read_text().strip())
            self.assertTrue(archive.is_file())
            inputs = root / "link.txt"
            inputs.write_text(str(archive) + "\n", encoding="utf-8")
            consumer = root / "consumer"
            consumer.mkdir()
            (consumer / "main.c").write_text(
                "int fixture_value(void);\nint main(void) { return fixture_value() == 42 ? 0 : 1; }\n")
            (consumer / "CMakeLists.txt").write_text(
                'cmake_minimum_required(VERSION 3.16)\nproject(consumer C)\n'
                'include("${HELPER}")\n'
                's2a_read_native_link_inputs("${INPUT}" entries)\n'
                'add_executable(consumer main.c)\n'
                'target_link_libraries(consumer PRIVATE ${entries})\n',
                encoding="utf-8"
            )
            consumer_build = root / "consumer-build"
            self.run_command([CMAKE, "-S", consumer, "-B", consumer_build, "-G", "Unix Makefiles",
                              f"-DHELPER={HELPER}", f"-DINPUT={inputs}"])
            self.run_command([CMAKE, "--build", consumer_build])
            executable = consumer_build / ("consumer.exe" if shutil.which("cmd.exe") else "consumer")
            self.run_command([executable])


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cmake", default=CMAKE)
    parser.add_argument("--helper", type=Path, default=HELPER)
    args, remaining = parser.parse_known_args()
    CMAKE, HELPER = args.cmake, args.helper.resolve()
    unittest.main(argv=[__file__, *remaining])
