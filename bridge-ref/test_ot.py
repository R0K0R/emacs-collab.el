import os
import random
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ot  # noqa: E402

ALPHABET = ["a", "b", "c", " ", "\n", "é", "😀", "𝒳", "𝟘", "漢", "🇰"]


def rand_str(rng, n):
    return "".join(rng.choice(ALPHABET) for _ in range(n))


def rand_op(rng, doc):
    """Random op over doc; deliberately not canonical (may need normalize)."""
    op = []
    left = len(doc)
    while left > 0 or rng.random() < 0.3:
        r = rng.random()
        if r < 0.3 and left > 0:
            n = rng.randint(1, left)
            op.append(n)
            left -= n
        elif r < 0.6 and left > 0:
            n = rng.randint(1, left)
            op.append(-n)
            left -= n
        elif r < 0.9:
            op.append(rand_str(rng, rng.randint(1, 4)))
        else:
            break
    if left:
        op.append(left)
    return op


def is_canonical(op):
    return ot.normalize(op) == op


class UnitTests(unittest.TestCase):
    def test_spec_example(self):
        self.assertEqual(ot.apply("hello", [1, "a", -2, 2]), "halo")

    def test_lengths(self):
        op = [2, "xyz", -1, 3]
        self.assertEqual(ot.base_length(op), 6)
        self.assertEqual(ot.target_length(op), 8)

    def test_codepoints(self):
        d = "a😀𝒳b"
        self.assertEqual(len(d), 4)
        self.assertEqual(ot.apply(d, [1, -2, 1]), "ab")
        self.assertEqual(ot.apply(d, [2, "😀", 2]), "a😀😀𝒳b")

    def test_apply_mismatch(self):
        with self.assertRaises(ValueError):
            ot.apply("abc", [2])
        with self.assertRaises(ValueError):
            ot.apply("abc", [4])

    def test_normalize(self):
        self.assertEqual(ot.normalize([1, 2, "a", "", "b", 0, -1, -2]), [3, "ab", -3])
        self.assertEqual(ot.normalize([-1, "x"]), ["x", -1])
        self.assertEqual(ot.normalize([]), [])

    def test_from_change(self):
        self.assertEqual(ot.from_change(5, 1, 2, "a"), [1, "a", -2, 2])
        self.assertEqual(ot.from_change(0, 0, 0, "hi"), ["hi"])
        self.assertEqual(ot.from_change(3, 0, 0, ""), [3])
        self.assertEqual(ot.from_change(3, 3, 0, "z"), [3, "z"])
        with self.assertRaises(ValueError):
            ot.from_change(3, 2, 2, "")

    def test_is_noop(self):
        self.assertTrue(ot.is_noop([]))
        self.assertTrue(ot.is_noop([5]))
        self.assertTrue(ot.is_noop([2, 3]))
        self.assertFalse(ot.is_noop(["a", 3]))
        self.assertFalse(ot.is_noop([-1]))

    def test_transform_insert_tie(self):
        a, b = ["A", 3], ["B", 3]
        ap, bp = ot.transform(a, b)
        d = "xyz"
        r1 = ot.apply(ot.apply(d, a), bp)
        r2 = ot.apply(ot.apply(d, b), ap)
        self.assertEqual(r1, "ABxyz")  # a's insert first
        self.assertEqual(r2, "ABxyz")

    def test_transform_insert_tie_middle(self):
        a, b = [1, "A", 2], [1, "B", 2]
        ap, bp = ot.transform(a, b)
        self.assertEqual(ot.apply(ot.apply("xyz", a), bp), "xAByz")

    def test_transform_overlapping_deletes(self):
        d = "abcdef"
        a = [1, -3, 2]   # deletes bcd
        b = [2, -3, 1]   # deletes cde
        ap, bp = ot.transform(a, b)
        r1 = ot.apply(ot.apply(d, a), bp)
        r2 = ot.apply(ot.apply(d, b), ap)
        self.assertEqual(r1, "af")
        self.assertEqual(r2, "af")

    def test_transform_delete_contains_insert(self):
        d = "abcdef"
        a = [1, -4, 1]       # deletes bcde
        b = [3, "XY", 3]     # inserts inside the deleted range
        ap, bp = ot.transform(a, b)
        r1 = ot.apply(ot.apply(d, a), bp)
        r2 = ot.apply(ot.apply(d, b), ap)
        self.assertEqual(r1, r2)
        self.assertEqual(r1, "aXYf")

    def test_transform_mismatch(self):
        with self.assertRaises(ValueError):
            ot.transform([3], [4])

    def test_compose_basic(self):
        d = "hello"
        a = [1, "a", -2, 2]       # halo
        b = [4, "!"]              # halo!
        self.assertEqual(ot.apply(d, ot.compose(a, b)), "halo!")

    def test_compose_insert_then_delete_it(self):
        c = ot.compose(["abc", 2], [-3, 2])
        self.assertEqual(ot.apply("xy", c), "xy")
        self.assertTrue(ot.is_noop(c))

    def test_compose_mismatch(self):
        with self.assertRaises(ValueError):
            ot.compose([2], [3])


class PropertyTests(unittest.TestCase):
    N = 4000

    def test_transform_convergence(self):
        rng = random.Random(20240601)
        for _ in range(self.N):
            d = rand_str(rng, rng.randint(0, 12))
            a, b = rand_op(rng, d), rand_op(rng, d)
            ap, bp = ot.transform(a, b)
            r1 = ot.apply(ot.apply(d, a), bp)
            r2 = ot.apply(ot.apply(d, b), ap)
            self.assertEqual(r1, r2, (d, a, b, ap, bp))
            self.assertTrue(is_canonical(ap) and is_canonical(bp), (a, b, ap, bp))
            self.assertEqual(ot.base_length(ap), ot.target_length(b))
            self.assertEqual(ot.base_length(bp), ot.target_length(a))

    def test_transform_tie_order(self):
        rng = random.Random(7)
        for _ in range(500):
            d = rand_str(rng, rng.randint(0, 6))
            p = rng.randint(0, len(d))
            x, y = rand_str(rng, 2), rand_str(rng, 2)
            a = ot.from_change(len(d), p, 0, x)
            b = ot.from_change(len(d), p, 0, y)
            ap, bp = ot.transform(a, b)
            self.assertEqual(ot.apply(ot.apply(d, a), bp), d[:p] + x + y + d[p:])

    def test_compose(self):
        rng = random.Random(424242)
        for _ in range(self.N):
            d = rand_str(rng, rng.randint(0, 12))
            a = rand_op(rng, d)
            d1 = ot.apply(d, a)
            b = rand_op(rng, d1)
            c = ot.compose(a, b)
            self.assertEqual(ot.apply(d, c), ot.apply(d1, b), (d, a, b, c))
            self.assertTrue(is_canonical(c), c)
            self.assertEqual(ot.base_length(c), len(d))
            self.assertEqual(ot.target_length(c), len(ot.apply(d1, b)))

    def test_normalize_idempotent_and_semantic(self):
        rng = random.Random(99)
        for _ in range(self.N):
            d = rand_str(rng, rng.randint(0, 12))
            a = rand_op(rng, d)
            n = ot.normalize(a)
            self.assertTrue(is_canonical(n))
            self.assertEqual(ot.normalize(n), n)
            self.assertEqual(ot.apply(d, n), ot.apply(d, a))

    def test_from_change_semantics(self):
        rng = random.Random(5)
        for _ in range(self.N):
            d = rand_str(rng, rng.randint(0, 12))
            p = rng.randint(0, len(d))
            k = rng.randint(0, len(d) - p)
            ins = rand_str(rng, rng.randint(0, 3))
            op = ot.from_change(len(d), p, k, ins)
            self.assertEqual(ot.apply(d, op), d[:p] + ins + d[p + k:])
            self.assertTrue(is_canonical(op))

    def test_transform_composed(self):
        # a composed op still converges against a concurrent op
        rng = random.Random(31337)
        for _ in range(1000):
            d = rand_str(rng, rng.randint(0, 10))
            a = rand_op(rng, d)
            b = rand_op(rng, ot.apply(d, a))
            c = rand_op(rng, d)
            ab = ot.compose(a, b)
            abp, cp = ot.transform(ab, c)
            self.assertEqual(ot.apply(ot.apply(d, ab), cp),
                             ot.apply(ot.apply(d, c), abp))


if __name__ == "__main__":
    unittest.main()
