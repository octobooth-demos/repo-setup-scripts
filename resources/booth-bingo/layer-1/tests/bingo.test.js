import { test } from 'node:test';
import assert from 'node:assert/strict';
import { LINES, checkWin } from '../src/bingo.js';

const mark = (...cells) => Array.from({ length: 9 }, (_, i) => cells.includes(i));

test('there are 8 winning lines', () => {
  assert.equal(LINES.length, 8);
});

test('an empty card is not a win', () => {
  assert.equal(checkWin(mark()), null);
});

test('only the FREE square is not a win', () => {
  assert.equal(checkWin(mark(4)), null);
});

for (const line of LINES) {
  test(`line ${line.join('-')} wins`, () => {
    assert.deepEqual(checkWin(mark(...line)), line);
  });
}

test('two in a row is not a win', () => {
  assert.equal(checkWin(mark(0, 1, 4)), null);
});

test('rejects a card that is not 3x3', () => {
  assert.throws(() => checkWin([true, true, true]), TypeError);
});
