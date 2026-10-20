import { SQUARES, createBoard, toggle } from './src/board.js';

const boardEl = document.getElementById('board');
let board = createBoard();

function render() {
  boardEl.replaceChildren(...SQUARES.map((label, i) => {
    const cell = document.createElement('button');
    cell.type = 'button';
    cell.className = 'cell';
    cell.textContent = label;
    cell.setAttribute('aria-pressed', String(board[i]));
    cell.addEventListener('click', () => onTap(i));
    return cell;
  }));
}

function onTap(index) {
  board = toggle(board, index);
  render();
}

render();
