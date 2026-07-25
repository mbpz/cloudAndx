import UI from './ui.js';

const GESTURE_END_DELAY_MS = 90;

function installTouchGestures() {
    if (!UI.rfb || !UI.rfb._canvas) {
        window.setTimeout(installTouchGestures, 100);
        return;
    }

    if (UI.rfb.__cloudAndxTouchInstalled) {
        window.setTimeout(installTouchGestures, 500);
        return;
    }

    const rfb = UI.rfb;
    const canvas = rfb._canvas;
    let pointer = { x: canvas.clientWidth / 2, y: canvas.clientHeight / 2 };
    let touching = false;
    let endTimer;

    rfb.__cloudAndxTouchInstalled = true;

    canvas.addEventListener('mousemove', (event) => {
        const bounds = canvas.getBoundingClientRect();
        pointer = {
            x: Math.max(0, Math.min(bounds.width - 1, event.clientX - bounds.left)),
            y: Math.max(0, Math.min(bounds.height - 1, event.clientY - bounds.top)),
        };
    }, true);

    canvas.addEventListener('wheel', (event) => {
        if (!UI.rfb || UI.rfb.viewOnly || UI.rfb.dragViewport) {
            return;
        }

        event.preventDefault();
        event.stopImmediatePropagation();

        if (!touching) {
            touching = true;
            rfb._sendMouse(pointer.x, pointer.y, 1);
        }

        const bounds = canvas.getBoundingClientRect();
        pointer.x = Math.max(0, Math.min(bounds.width - 1, pointer.x - event.deltaX));
        pointer.y = Math.max(0, Math.min(bounds.height - 1, pointer.y - event.deltaY));
        rfb._sendMouse(pointer.x, pointer.y, 1);

        window.clearTimeout(endTimer);
        endTimer = window.setTimeout(() => {
            rfb._sendMouse(pointer.x, pointer.y, 0);
            touching = false;
        }, GESTURE_END_DELAY_MS);
    }, { capture: true, passive: false });

    window.setTimeout(installTouchGestures, 500);
}

installTouchGestures();
