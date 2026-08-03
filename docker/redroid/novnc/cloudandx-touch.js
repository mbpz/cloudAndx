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
    let mouseMask = 0;
    let endTimer;

    rfb.__cloudAndxTouchInstalled = true;

    const buttonMasks = {
        0: 1,   // primary/left -> Android touch
        1: 4,   // secondary/right -> Android back
        2: 2,   // auxiliary/middle
        3: 128, // back
        4: 256, // forward
    };

    const updatePointer = (event) => {
        const bounds = canvas.getBoundingClientRect();
        pointer = {
            x: Math.max(0, Math.min(bounds.width - 1, event.clientX - bounds.left)),
            y: Math.max(0, Math.min(bounds.height - 1, event.clientY - bounds.top)),
        };
    };

    const sendMouse = (event, mask) => {
        if (!UI.rfb || UI.rfb.viewOnly) {
            return;
        }
        updatePointer(event);
        rfb._sendMouse(pointer.x, pointer.y, mask);
    };

    // noVNC's generic handlers rely on a browser-generated compatibility
    // mouse event. Safari/WebKit can suppress that event when the canvas is
    // scaled, which leaves the cursor visible but sends no Android input.
    // Capture the native mouse sequence explicitly and feed the same RFB
    // pointer messages noVNC uses internally. Touch events remain owned by
    // noVNC's GestureHandler so one- and two-finger gestures keep their
    // normal semantics.
    canvas.addEventListener('mousedown', (event) => {
        const buttonMask = buttonMasks[event.button];
        if (buttonMask === undefined || !UI.rfb || UI.rfb.viewOnly) {
            return;
        }
        event.preventDefault();
        event.stopImmediatePropagation();
        mouseMask |= buttonMask;
        canvas.focus();
        sendMouse(event, mouseMask);
    }, true);

    canvas.addEventListener('pointerdown', (event) => {
        if (event.pointerType !== 'mouse') {
            return;
        }
        try {
            canvas.setPointerCapture(event.pointerId);
        } catch (_) {
            // Older WebKit releases do not expose pointer capture on canvas.
        }
    }, true);

    canvas.addEventListener('pointerup', (event) => {
        if (event.pointerType !== 'mouse') {
            return;
        }
        try {
            canvas.releasePointerCapture(event.pointerId);
        } catch (_) {
            // The corresponding pointerdown may have happened outside canvas.
        }
    }, true);

    canvas.addEventListener('mousemove', (event) => {
        if (!UI.rfb || UI.rfb.viewOnly) {
            return;
        }
        updatePointer(event);
        if (mouseMask) {
            event.preventDefault();
            event.stopImmediatePropagation();
            rfb._sendMouse(pointer.x, pointer.y, mouseMask);
        }
    }, true);

    canvas.addEventListener('mouseup', (event) => {
        const buttonMask = buttonMasks[event.button];
        if (buttonMask === undefined || !UI.rfb || UI.rfb.viewOnly) {
            return;
        }
        event.preventDefault();
        event.stopImmediatePropagation();
        mouseMask &= ~buttonMask;
        sendMouse(event, mouseMask);
    }, true);

    canvas.addEventListener('mousemove', (event) => {
        updatePointer(event);
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
