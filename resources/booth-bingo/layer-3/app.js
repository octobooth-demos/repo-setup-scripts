import { SQUARES, createBoard, toggle } from './src/board.js';
import { checkWin } from './src/bingo.js';

const boardEl = document.getElementById('board');
const bannerEl = document.getElementById('banner');
let board = createBoard();
let winningLine = null;

function render() {
  boardEl.replaceChildren(...SQUARES.map((label, i) => {
    const cell = document.createElement('button');
    cell.type = 'button';
    cell.className = 'cell';
    cell.textContent = label;
    cell.setAttribute('aria-pressed', String(board[i]));
    cell.classList.toggle('win', winningLine?.includes(i) ?? false);
    cell.addEventListener('click', () => onTap(i));
    return cell;
  }));
  bannerEl.hidden = !winningLine;
}

function onTap(index) {
  board = toggle(board, index);
  winningLine = checkWin(board);
  render();
}

function reset() {
  board = createBoard();
  winningLine = null;
  render();
}

document.getElementById('reset').addEventListener('click', reset);

render();
