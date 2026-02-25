#!/usr/bin/env python
import argparse

class InvalidStripeGeometryConfiguration(Exception):
    def __init__(self, message):
        super(InvalidStripeGeometryConfiguration, self).__init__(message)

class InvalidBlockHeight(InvalidStripeGeometryConfiguration):
    def __init__(self):
        message = 'Invalid BlockHeight'
        super(InvalidBlockHeight, self).__init__(message)

class StripeHeightNotMultipleOfBlockHeight(InvalidStripeGeometryConfiguration):
    def __init__(self):
        message = 'StripeHeight is not a multiple of BlockHeight'
        super(StripeHeightNotMultipleOfBlockHeight, self).__init__(message)

class StripePitchNotMultipleOfBlockHeight(InvalidStripeGeometryConfiguration):
    def __init__(self):
        message = 'StripePitch is not a multiple of BlockHeight'
        super(StripePitchNotMultipleOfBlockHeight, self).__init__(message)

class StripeOffsetNotMultipleOfBlockHeight(InvalidStripeGeometryConfiguration):
    def __init__(self):
        message = 'StripeOffset is not a multiple of BlockHeight'
        super(StripeOffsetNotMultipleOfBlockHeight, self).__init__(message)

class BufferHeightNotMultipleOfBlockHeight(InvalidStripeGeometryConfiguration):
    def __init__(self):
        message = 'Buffer height is not a multiple of BlockHeight'
        super(BufferHeightNotMultipleOfBlockHeight, self).__init__(message)

# Basic generators for StripeArrangement

def g_1X_1Y(unused=0):
    def g(count):
        for i in range(count):
            yield i
    g.name = '1X_1Y'
    g.block = 1
    return g

def g_1X_1YE(unused=0):
    def g(count):
        for i in range(count - 1, -1, -1):
            yield i
    g.name = '1X_1YE'
    g.block = 1
    return g

def g_1X_2YE(unused=0):
    def g(count):
        middle = count // 2
        i = 0
        while i < middle:
            yield i
            yield count - i - 1
            i += 1
    g.name = '1X_2YE'
    g.block = 1
    return g

def g_1X_2YM(block=2):
    block = block if block else 2
    if block % 2:
        raise InvalidBlockHeight
    def g(count):
        middle = count // 2
        half_block = block // 2
        i = 0
        while i + half_block <= middle:
            for x in range(half_block):
                yield middle - half_block - i + x
            for x in range(half_block):
                yield middle + i + x
            i += block // 2
    g.name = '1X_2YM'
    g.block = block
    return g

def g_1X_2Y(unused=0):
    def g(count):
        middle = count // 2
        i = 0
        while i < middle:
            yield i
            yield middle + i
            i += 1
    g.name = '1X_2Y'
    g.block = 1
    return g

def g_1X_3Y(unused=0):
    def g(count):
        one_third = count // 3
        i = 0
        while i < one_third:
            yield 0 * one_third + i
            yield 1 * one_third + i
            yield 2 * one_third + i
            i += 1
    g.name = '1X_3Y'
    g.block = 1
    return g

assert list(g_1X_1Y()(8))    == [0, 1, 2, 3, 4, 5, 6, 7]
assert list(g_1X_1YE()(10))  == [9, 8, 7, 6, 5, 4, 3, 2, 1, 0]
assert list(g_1X_2YE()(12))  == [0, 11, 1, 10, 2, 9, 3, 8, 4, 7, 5, 6]
assert list(g_1X_2YM(2)(12)) == [5, 6, 4, 7, 3, 8, 2, 9, 1, 10, 0, 11]
assert list(g_1X_2YM(4)(12)) == [4, 5, 6, 7, 2, 3, 8, 9, 0, 1, 10, 11]
assert list(g_1X_2Y()(12))   == [0, 6, 1, 7, 2, 8, 3, 9, 4, 10, 5, 11]
assert list(g_1X_3Y()(12))   == [0, 4, 8, 1, 5, 9, 2, 6, 10, 3, 7, 11]


# Combinators

def drop(n, gen):
    while True:
        try:
            x = next(gen)
            if n > 0:
                n -= 1
            else:
                yield x
        except StopIteration:
            return

def keep_n_in_m(n, m, gen):
    i = 0
    while True:
        try:
            x = next(gen)
            if (i % m) < n:
                yield x
            i += 1
        except StopIteration:
            return

def rg(n):
    return (x for x in range(n))
assert list(drop(0, rg(7))) == [0, 1, 2, 3, 4, 5, 6]
assert list(drop(3, rg(7))) == [3, 4, 5, 6]
assert list(keep_n_in_m(1, 1, rg(7))) == [0, 1, 2, 3, 4, 5, 6]
assert list(keep_n_in_m(1, 2, rg(7))) == [0, 2, 4, 6]
assert list(keep_n_in_m(2, 4, rg(7))) == [0, 1, 4, 5]
assert list(keep_n_in_m(2, 3, rg(7))) == [0, 1, 3, 4, 6]


# get_lines returns the list of "buffer line indexes" that are filled
def get_lines(geometry, line_count, stripe_height=0, stripe_pitch=0, stripe_offset=0):
    stripe_height = stripe_height or geometry.block
    stripe_pitch = stripe_pitch or stripe_height
    if geometry.name == '1X_2YM':
        if stripe_height % geometry.block:
            raise StripeHeightNotMultipleOfBlockHeight
        if stripe_pitch % geometry.block:
            raise StripePitchNotMultipleOfBlockHeight
        if stripe_offset % geometry.block:
            raise StripeOffsetNotMultipleOfBlockHeight
    if line_count % geometry.block:
        raise BufferHeightNotMultipleOfBlockHeight
    gen = keep_n_in_m(stripe_height, stripe_pitch, drop(stripe_offset, geometry(line_count)))
    return list(gen)

assert get_lines(g_1X_1Y(), 10)                                                     == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
assert get_lines(g_1X_1Y(), 10, stripe_pitch=2)                                     == [0, 2, 4, 6, 8]
assert get_lines(g_1X_1Y(), 10, stripe_height=2, stripe_pitch=4)                    == [0, 1, 4, 5, 8, 9]
assert get_lines(g_1X_1Y(), 10, stripe_height=2, stripe_pitch=4, stripe_offset=2)   == [2, 3, 6, 7]

assert get_lines(g_1X_1YE(), 10)                                                    == [9, 8, 7, 6, 5, 4, 3, 2, 1, 0]
assert get_lines(g_1X_1YE(), 10, stripe_height=2, stripe_pitch=4)                   == [9, 8, 5, 4, 1, 0]
assert get_lines(g_1X_1YE(), 10, stripe_height=2, stripe_pitch=4, stripe_offset=2)  == [7, 6, 3, 2]

assert get_lines(g_1X_2YE(), 12) == [0, 11, 1, 10, 2, 9, 3, 8, 4, 7, 5, 6]
assert get_lines(g_1X_2YE(), 12, stripe_height=1, stripe_pitch=2, stripe_offset=0) == [ 0,  1, 2, 3, 4, 5]
assert get_lines(g_1X_2YE(), 12, stripe_height=1, stripe_pitch=2, stripe_offset=1) == [11, 10, 9, 8, 7, 6]
assert get_lines(g_1X_2YE(), 12, stripe_height=2, stripe_pitch=4, stripe_offset=0) == [0, 11, 2, 9, 4, 7]
assert get_lines(g_1X_2YE(), 12, stripe_height=2, stripe_pitch=4, stripe_offset=2) == [1, 10, 3, 8, 5, 6]

assert get_lines(g_1X_2YM(2), 12) == [5, 6, 4, 7, 3, 8, 2, 9, 1, 10, 0, 11]
assert get_lines(g_1X_2YM(2), 12, stripe_height=2, stripe_pitch=4, stripe_offset=0) == [5, 6, 3, 8, 1, 10]
assert get_lines(g_1X_2YM(2), 12, stripe_height=2, stripe_pitch=4, stripe_offset=2) == [4, 7, 2, 9, 0, 11]
assert get_lines(g_1X_2YM(4), 12) == [4, 5, 6, 7, 2, 3, 8, 9, 0, 1, 10, 11]
assert get_lines(g_1X_2YM(4), 12, stripe_height=4, stripe_pitch=8, stripe_offset=0) == [4, 5, 6, 7, 0, 1, 10, 11]
assert get_lines(g_1X_2YM(4), 12, stripe_height=4, stripe_pitch=8, stripe_offset=4) == [2, 3, 8, 9]

assert get_lines(g_1X_2Y(), 12) == [0, 6, 1, 7, 2, 8, 3, 9, 4, 10, 5, 11]
assert get_lines(g_1X_2Y(), 12, stripe_height=2, stripe_pitch=4, stripe_offset=0) == [0, 6, 2, 8, 4, 10]
assert get_lines(g_1X_2Y(), 12, stripe_height=2, stripe_pitch=4, stripe_offset=2) == [1, 7, 3, 9, 5, 11]

assert get_lines(g_1X_3Y(), 12) == [0, 4, 8, 1, 5, 9, 2, 6, 10, 3, 7, 11]
assert get_lines(g_1X_3Y(), 12, stripe_height=3, stripe_pitch=6, stripe_offset=0) == [0, 4, 8, 2, 6, 10]
assert get_lines(g_1X_3Y(), 12, stripe_height=3, stripe_pitch=6, stripe_offset=3) == [1, 5, 9, 3, 7, 11]

def show_geometry(geometry, line_count, stripe_height=0, stripe_pitch=0, stripe_offset=0):
    ixs = get_lines(geometry, line_count)
    readout = [None for i in range(line_count)]
    for (ln, ix) in enumerate(ixs):
        readout[ix] = ln
    ixs = get_lines(geometry, line_count, stripe_height, stripe_pitch, stripe_offset)
    received = [None for i in range(line_count)]
    for (ln, ix) in enumerate(ixs):
        received[ix] = ln
    bank_count = 1 if stripe_pitch == 0 or stripe_height == 0 else stripe_pitch // stripe_height
    print('StripeArrangement=%s' % geometry.name)
    if geometry.name == '1X_2YM':
        print('BlockHeight=%i' % geometry.block)
    print('StripeHeight=%i' % stripe_height)
    print('StripePitch=%i' % stripe_pitch)
    print('StripeOffset=%i' % stripe_offset)
    print('')
    print('        %-28s       %s ' % ('User buffer', 'Sensor readout'))
    print('      +' + '-' * 30 + '+   +' + '-' * 35 + '+')
    for ix in range(line_count):
        ln = readout[ix]
        cam_block = ln // geometry.block
        cam = 'sent # %-3i' % ln
        if geometry.name == '1X_2YM':
            cam += ' block %-3i' % cam_block
        if bank_count > 1:
            cam += ' (bank %i)' % (cam_block % bank_count)
        ln = received[ix]
        if ln is None:
            recv = ''
        else:
            recv = 'received # %-3i' % ln
            if geometry.name == '1X_2YM':
                recv += ' block %-3i' % (ln // geometry.block)
        print('  %3i | %-28s |   | %-33s |' % (ix, recv, cam))
    print('      +' + '-' * 30 + '+   +' + '-' * 35 + '+')
    print('')
    print('Received -> Buffer: {%s}' % ', '.join([str(ix) for ix in ixs]))


def parse_args():
    parser = argparse.ArgumentParser(description='StripeArrangement view')
    parser.add_argument('-g', '--geometry',         default='1X_1Y',    type=str)
    parser.add_argument('-c', '--line-count',       default=16,         type=int)
    parser.add_argument('-s', '--stripe-height',    default=0,          type=int)
    parser.add_argument('-p', '--stripe-pitch',     default=0,          type=int)
    parser.add_argument('-o', '--stripe-offset',    default=0,          type=int)
    parser.add_argument('-b', '--block-height',     default=0,          type=int)
    return parser.parse_args()

geometries = { '1X_1Y':  g_1X_1Y
             , '1X_1YE': g_1X_1YE
             , '1X_2YE': g_1X_2YE
             , '1X_2YM': g_1X_2YM
             , '1X_2Y':  g_1X_2Y
             , '1X_3Y':  g_1X_3Y }

if __name__ == '__main__':
    args = parse_args()
    try:
        if not args.geometry in geometries:
            raise InvalidStripeGeometryConfiguration("Unknown stripe geometry '%s'" % args.geometry)
        g = geometries[args.geometry]
        show_geometry(g(args.block_height), args.line_count, args.stripe_height, args.stripe_pitch, args.stripe_offset)
    except Exception as exc:
        print('Error: %s' % exc)
