"""ot.js-style TextOperation over Unicode code points (PROTOCOL.md section 3).

An operation is a list of components: a positive int retains that many
characters, a str inserts it, a negative int deletes that many.  Python str
indexes by code point, so lengths here are code-point lengths.

Port of the algorithm in Operational-Transformation/ot.js src/text-operation.js
(MIT licence), adapted to plain-list operations.
"""


def _is_int(x):
    return isinstance(x, int) and not isinstance(x, bool)


def _is_ret(o):
    return _is_int(o) and o > 0


def _is_del(o):
    return _is_int(o) and o < 0


def _is_ins(o):
    return isinstance(o, str)


class _Builder:
    """Accumulates components, merging adjacent ones of the same kind.

    As in ot.js, an insert placed right after a delete is moved before it, so
    the canonical order is insert-then-delete.
    """

    def __init__(self):
        self.ops = []

    def retain(self, n):
        if n == 0:
            return
        if self.ops and _is_ret(self.ops[-1]):
            self.ops[-1] += n
        else:
            self.ops.append(n)

    def insert(self, s):
        if s == "":
            return
        ops = self.ops
        if ops and _is_ins(ops[-1]):
            ops[-1] += s
        elif ops and _is_del(ops[-1]):
            if len(ops) >= 2 and _is_ins(ops[-2]):
                ops[-2] += s
            else:
                ops.insert(len(ops) - 1, s)
        else:
            ops.append(s)

    def delete(self, n):
        if n == 0:
            return
        n = abs(n)
        if self.ops and _is_del(self.ops[-1]):
            self.ops[-1] -= n
        else:
            self.ops.append(-n)


def _check(op):
    if not isinstance(op, (list, tuple)):
        raise ValueError("operation must be a list")
    for o in op:
        if not (_is_int(o) or isinstance(o, str)):
            raise ValueError("bad component %r" % (o,))


def normalize(op):
    """Merge adjacent same-kind components, drop empty ones, canonical order."""
    _check(op)
    b = _Builder()
    for o in op:
        if _is_ins(o):
            b.insert(o)
        elif o > 0:
            b.retain(o)
        elif o < 0:
            b.delete(o)
    return b.ops


def base_length(op):
    _check(op)
    return sum(o if o > 0 else -o for o in op if _is_int(o))


def target_length(op):
    _check(op)
    return sum(len(o) if _is_ins(o) else o for o in op if _is_ins(o) or o > 0)


def is_noop(op):
    op = normalize(op)
    return len(op) == 0 or (len(op) == 1 and _is_ret(op[0]))


def apply(doc, op):
    _check(op)
    if base_length(op) != len(doc):
        raise ValueError("base length %d does not match document length %d"
                         % (base_length(op), len(doc)))
    out = []
    i = 0
    for o in op:
        if _is_ins(o):
            out.append(o)
        elif o > 0:
            out.append(doc[i:i + o])
            i += o
        else:
            i += -o
    return "".join(out)


def from_change(doc_len, pos, del_len, ins):
    """Op replacing doc[pos:pos+del_len] with ins in a doc of doc_len chars."""
    if pos < 0 or del_len < 0 or pos + del_len > doc_len:
        raise ValueError("change out of range")
    b = _Builder()
    b.retain(pos)
    b.delete(del_len)
    b.insert(ins)
    b.retain(doc_len - pos - del_len)
    return b.ops


def _rest(o, m, it):
    """Consume m units of int component o; return the next current component."""
    r = o - m if o > 0 else o + m
    return r if r != 0 else next(it, None)


def _rest_str(o, m, it):
    r = o[m:]
    return r if r else next(it, None)


def compose(a, b):
    """Op equivalent to applying a, then b."""
    a = normalize(a)
    b = normalize(b)
    if target_length(a) != base_length(b):
        raise ValueError("compose: target length of a != base length of b")
    res = _Builder()
    ia, ib = iter(a), iter(b)
    o1, o2 = next(ia, None), next(ib, None)
    while o1 is not None or o2 is not None:
        if _is_del(o1):
            res.delete(o1)
            o1 = next(ia, None)
            continue
        if _is_ins(o2):
            res.insert(o2)
            o2 = next(ib, None)
            continue
        if o1 is None or o2 is None:
            raise ValueError("compose: operations too short")
        if _is_ret(o1) and _is_ret(o2):
            m = min(o1, o2)
            res.retain(m)
            o1, o2 = _rest(o1, m, ia), _rest(o2, m, ib)
        elif _is_ins(o1) and _is_ret(o2):
            m = min(len(o1), o2)
            res.insert(o1[:m])
            o1, o2 = _rest_str(o1, m, ia), _rest(o2, m, ib)
        elif _is_ins(o1) and _is_del(o2):
            m = min(len(o1), -o2)
            o1, o2 = _rest_str(o1, m, ia), _rest(o2, m, ib)
        else:  # retain, delete
            m = min(o1, -o2)
            res.delete(m)
            o1, o2 = _rest(o1, m, ia), _rest(o2, m, ib)
    return res.ops


def transform(a, b):
    """Return (a', b') with apply(apply(d,a),b') == apply(apply(d,b),a').

    When both insert at the same position, a's insert comes first.
    """
    a = normalize(a)
    b = normalize(b)
    if base_length(a) != base_length(b):
        raise ValueError("transform: both operations must have the same base length")
    ap, bp = _Builder(), _Builder()
    ia, ib = iter(a), iter(b)
    o1, o2 = next(ia, None), next(ib, None)
    while o1 is not None or o2 is not None:
        if _is_ins(o1):
            ap.insert(o1)
            bp.retain(len(o1))
            o1 = next(ia, None)
            continue
        if _is_ins(o2):
            ap.retain(len(o2))
            bp.insert(o2)
            o2 = next(ib, None)
            continue
        if o1 is None or o2 is None:
            raise ValueError("transform: operations too short")
        if _is_ret(o1) and _is_ret(o2):
            m = min(o1, o2)
            ap.retain(m)
            bp.retain(m)
        elif _is_del(o1) and _is_del(o2):
            m = min(-o1, -o2)
        elif _is_del(o1) and _is_ret(o2):
            m = min(-o1, o2)
            ap.delete(m)
        else:  # retain, delete
            m = min(o1, -o2)
            bp.delete(m)
        o1, o2 = _rest(o1, m, ia), _rest(o2, m, ib)
    return ap.ops, bp.ops
