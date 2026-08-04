export function consumeMotion(value, maximumStep) {
    if (!Number.isFinite(value) || !Number.isFinite(maximumStep) || maximumStep <= 0) {
        throw new TypeError('motion and maximumStep must be finite, with maximumStep greater than zero');
    }

    const step = Math.max(-maximumStep, Math.min(maximumStep, value));
    const remaining = Math.abs(value - step) < 0.01 ? 0 : value - step;
    return { step, remaining };
}

export function wheelPixels(event, pageSize) {
    const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? pageSize : 1;
    return {
        x: event.deltaX * unit,
        y: event.deltaY * unit,
    };
}
