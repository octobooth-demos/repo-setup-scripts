import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SQUARES, FREE_INDEX, createBoard, toggle } from '../src/board.js';

test('a new card has nine squares with only FREE marked', () => {
  const board = createBoard();
  assert.equal(board.length, SQUARES.length);
  assert.equal(board.length, 9);
  assert.deepEqual(
    board.map((marked, i) => (marked ? i : -1)).filter((i) => i >= 0),
    [FREE_INDEX],
  );
});

test('toggle marks and unmarks a square without mutating the input', () => {
  const board = createBoard();
  const marked = toggle(board, 0);
  assert.equal(marked[0], true);
  assert.equal(board[0], false);
  assert.equal(toggle(marked, 0)[0], false);
});

test('the FREE square cannot be unmarked', () => {
  assert.equal(toggle(createBoard(), FREE_INDEX)[FREE_INDEX], true);
});
