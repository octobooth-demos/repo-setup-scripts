import { SQUARES, createBoard, toggle } from './src/board.js';
import { checkWin } from './src/bingo.js';

const boardEl = document.getElementById('board');
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
}

function onTap(index) {
  board = toggle(board, index);
  winningLine = checkWin(board);
  render();
}

render();
