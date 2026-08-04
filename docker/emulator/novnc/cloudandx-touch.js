import UI from './ui.js';
import { consumeMotion, wheelPixels } from './cloudandx-motion.js';

const GESTURE_END_DELAY_MS = 110;
const WHEEL_SENSITIVITY = 0.65;
const MAX_WHEEL_STEP_PX = 18;

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
    let mouseFrame;
    let pendingMouseEvent;
    let wheelFrame;
    let pendingWheel = { x: 0, y: 0 };
    let wheelEnding = false;

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

    const flushMouseMove = () => {
        mouseFrame = undefined;
        if (!pendingMouseEvent || !mouseMask || !UI.rfb || UI.rfb.viewOnly) {
            pendingMouseEvent = undefined;
            return;
        }
        const event = pendingMouseEvent;
        pendingMouseEvent = undefined;
        sendMouse(event, mouseMask);
    };

    const queueMouseMove = (event) => {
        pendingMouseEvent = event;
        if (mouseFrame === undefined) {
            mouseFrame = window.requestAnimationFrame(flushMouseMove);
        }
    };

    const finishWheelGesture = () => {
        if (touching) {
            rfb._sendMouse(pointer.x, pointer.y, 0);
            touching = false;
        }
        wheelEnding = false;
    };

    const sendWheelFrame = () => {
        wheelFrame = undefined;
        if (!UI.rfb || UI.rfb.viewOnly) {
            pendingWheel = { x: 0, y: 0 };
            finishWheelGesture();
            return;
        }

        const xMotion = consumeMotion(pendingWheel.x, MAX_WHEEL_STEP_PX);
        const yMotion = consumeMotion(pendingWheel.y, MAX_WHEEL_STEP_PX);
        pendingWheel = { x: xMotion.remaining, y: yMotion.remaining };

        if (xMotion.step !== 0 || yMotion.step !== 0) {
            if (!touching) {
                touching = true;
                rfb._sendMouse(pointer.x, pointer.y, 1);
            }
            const bounds = canvas.getBoundingClientRect();
            pointer.x = Math.max(0, Math.min(bounds.width - 1, pointer.x - xMotion.step));
            pointer.y = Math.max(0, Math.min(bounds.height - 1, pointer.y - yMotion.step));
            rfb._sendMouse(pointer.x, pointer.y, 1);
        }

        if (pendingWheel.x !== 0 || pendingWheel.y !== 0) {
            wheelFrame = window.requestAnimationFrame(sendWheelFrame);
        } else if (wheelEnding) {
            finishWheelGesture();
        }
    };

    const queueWheelFrame = () => {
        if (wheelFrame === undefined) {
            wheelFrame = window.requestAnimationFrame(sendWheelFrame);
        }
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
            queueMouseMove(event);
        }
    }, true);

    canvas.addEventListener('mouseup', (event) => {
        const buttonMask = buttonMasks[event.button];
        if (buttonMask === undefined || !UI.rfb || UI.rfb.viewOnly) {
            return;
        }
        event.preventDefault();
        event.stopImmediatePropagation();
        if (mouseFrame !== undefined) {
            window.cancelAnimationFrame(mouseFrame);
            flushMouseMove();
        }
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

        const bounds = canvas.getBoundingClientRect();
        const delta = wheelPixels(event, Math.max(bounds.width, bounds.height));
        pendingWheel.x += delta.x * WHEEL_SENSITIVITY;
        pendingWheel.y += delta.y * WHEEL_SENSITIVITY;
        pendingWheel.x = Math.max(-bounds.width, Math.min(bounds.width, pendingWheel.x));
        pendingWheel.y = Math.max(-bounds.height, Math.min(bounds.height, pendingWheel.y));
        wheelEnding = false;
        queueWheelFrame();

        window.clearTimeout(endTimer);
        endTimer = window.setTimeout(() => {
            wheelEnding = true;
            if (wheelFrame === undefined) {
                finishWheelGesture();
            }
        }, GESTURE_END_DELAY_MS);
    }, { capture: true, passive: false });

    window.setTimeout(installTouchGestures, 500);
}

installTouchGestures();
