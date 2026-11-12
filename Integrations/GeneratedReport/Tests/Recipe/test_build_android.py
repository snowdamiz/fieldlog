"""Recipe controls with mocked command dispatch; no native tools are run."""
import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/build-android.py"
spec = importlib.util.spec_from_file_location("fieldlog_recipe", SCRIPT)
recipe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recipe)


class RecipeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def argv(self, output, sdk=None, mixer=None, adapter=None):
        return [str(SCRIPT), "--mixer", str(mixer or self.root / "missing-cli"),
                "--sdk-checkout", str(sdk or self.root / "missing-sdk"),
                "--android-adapter-path", str(adapter or self.root / "missing-adapter"),
                "--output", str(output), "--prepare-only"]

    def refuse(self, output):
        with (
            patch.object(sys, "argv", self.argv(output)),
            patch.object(recipe.subprocess, "check_output") as git,
            patch.object(recipe.subprocess, "Popen") as cli,
            patch.object(recipe, "app_inputs") as inputs,
            contextlib.redirect_stderr(io.StringIO()) as error,
        ):
            with self.assertRaises(SystemExit) as caught:
                recipe.main()
        self.assertEqual(caught.exception.code, 2)
        self.assertIn("output must be absent", error.getvalue())
        git.assert_not_called()
        cli.assert_not_called()
        inputs.assert_not_called()

    def test_empty_directory_rejected_unchanged(self):
        output = self.root / "empty"
        output.mkdir()
        self.refuse(output)
        self.assertTrue(output.is_dir())
        self.assertEqual(list(output.iterdir()), [])

    def test_directory_user_files_preserved(self):
        output = self.root / "existing"
        output.mkdir()
        (output / "user").write_bytes(b"user\x00data")
        self.refuse(output)
        self.assertEqual((output / "user").read_bytes(), b"user\x00data")

    def test_existing_file_preserved(self):
        output = self.root / "file"
        output.write_bytes(b"preserve")
        self.refuse(output)
        self.assertEqual(output.read_bytes(), b"preserve")

    def test_output_symlink_preserved(self):
        target = self.root / "target"
        target.mkdir()
        output = self.root / "link"
        output.symlink_to(target, target_is_directory=True)
        self.refuse(output)
        self.assertTrue(output.is_symlink())
        self.assertTrue(target.is_dir())

    def test_dangling_symlink_preserved(self):
        output = self.root / "dangling"
        output.symlink_to(self.root / "absent")
        self.refuse(output)
        self.assertTrue(output.is_symlink())

    def inputs(self):
        sdk = self.root / "swift-checkout"
        (sdk / "sdk").mkdir(parents=True)
        (sdk / "sdk/Package.swift").write_text("// fixture")
        adapter = self.root / "independent-adapter"
        adapter.mkdir()
        (adapter / "unrelated-local-work").write_text("preserve")
        mixer = self.root / "mixer"
        mixer.write_text("fixture never executed")
        mixer.chmod(0o700)
        return sdk, adapter, mixer

    def test_absent_output_dispatches_separate_adapter_and_swift_pin(self):
        sdk, adapter, mixer = self.inputs()
        output = self.root / "fresh"
        commands = []

        class CompletedCreate:
            pid = 123456
            returncode = 0

            def __init__(self, argv, **kwargs):
                commands.append(argv)
                output.mkdir()

            def wait(self, **kwargs):
                return 0

        with (
            patch.object(sys, "argv", self.argv(output, sdk, mixer, adapter)),
            patch.object(recipe.subprocess, "check_output",
                         side_effect=[recipe.PIN, str(sdk), ""]) as git,
            patch.object(recipe.subprocess, "Popen", CompletedCreate),
            patch.object(recipe.os, "killpg", side_effect=ProcessLookupError),
            patch.object(recipe, "install_app_inputs") as install,
            contextlib.redirect_stdout(io.StringIO()),
        ):
            recipe.main()
        self.assertEqual(len(commands), 1)
        command = list(map(str, commands[0]))
        self.assertEqual(command[1:3], ["create", "FieldLogGenerated"])
        self.assertEqual(command[command.index("--android-adapter-path") + 1], str(adapter))
        self.assertEqual(command[command.index("--sdk-path") + 1], str(sdk / "sdk"))
        self.assertEqual(recipe.PIN, "8efc1a9e5b1602117f8211c95bfd4203cc91f689")
        self.assertTrue(all(call.args[0][3] == str(sdk) for call in git.call_args_list))
        install.assert_called_once()
        self.assertEqual((adapter / "unrelated-local-work").read_text(), "preserve")

    def test_dirty_swift_sdk_rejected_before_create(self):
        self.reject_sdk([recipe.PIN, "ROOT", " M sdk/Package.swift"])

    def test_wrong_swift_pin_rejected_before_create(self):
        self.reject_sdk(["wrong-pin"])

    def reject_sdk(self, replies):
        sdk, adapter, mixer = self.inputs()
        output = self.root / "fresh"
        replies = [str(sdk) if x == "ROOT" else x for x in replies]
        with (
            patch.object(sys, "argv", self.argv(output, sdk, mixer, adapter)),
            patch.object(recipe.subprocess, "check_output", side_effect=replies),
            patch.object(recipe.subprocess, "Popen") as cli,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            with self.assertRaises(SystemExit):
                recipe.main()
        cli.assert_not_called()
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
