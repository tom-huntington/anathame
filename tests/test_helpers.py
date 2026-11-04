"""Protect the conformance runner against false positives."""
import contextlib
import io
import unittest
from helpers import check

class ComparisonTests(unittest.TestCase):
    def compare(self, expected, actual):
        with contextlib.redirect_stdout(io.StringIO()):
            return check("fixture", "2 3", "mul", expected, actual)

    def test_shape_matters(self):
        self.assertFalse(self.compare("[[1 2]]", "[1 2]"))

    def test_failure_is_not_success(self):
        self.assertFalse(self.compare("6", "error: StackUnderflow"))

    def test_expected_errors_are_exact(self):
        self.assertTrue(self.compare("error: StackUnderflow", "error: StackUnderflow"))
        self.assertFalse(self.compare("error: UnknownPrimitive", "error: StackUnderflow"))

    def test_numeric_formatting_is_ignored(self):
        self.assertTrue(self.compare("[1 -2 0]", "[1.0 ¯2 -0]"))

if __name__ == "__main__":
    unittest.main()
