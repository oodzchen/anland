package com.anland.consumer;

/**
 * Android's own touchpad pointer acceleration, so a captured touchpad moves the
 * desktop cursor exactly as far as Android would have moved its own cursor.
 *
 * <p>Pointer capture hands over the pad's raw relative axes (device units),
 * skipping the curve Android normally applies. This reproduces that curve:
 * AOSP's AccelerationCurve.cpp segments, fed through the Gestures library the
 * way TouchpadInputMapper configures it:
 * <ul>
 *   <li>device units are converted to millimetres with the axis resolution;</li>
 *   <li>speed is the frame's travel over the time since the previous frame,
 *       where an implausible gap reuses the last plausible one
 *       (AccelFilterInterpreter, "Accel Min dt" / "Accel Max dt");</li>
 *   <li>gain(speed) = baseGain + reciprocal / speed, both scaled by the
 *       Android touchpad speed setting;</li>
 *   <li>the accelerated millimetres leave the library at 133 DPI
 *       (ScalingFilterInterpreter), which Android uses as display pixels.</li>
 * </ul>
 *
 * <p>Android-free on purpose, so the curve can be checked on a plain JVM.
 */
final class AndroidTouchpadAccel {

    /** {max speed (mm/s), base gain, reciprocal} from AOSP AccelerationCurve.cpp. */
    private static final double[][] SEGMENTS = {
            {32.002, 3.19, 0},
            {52.83, 4.79, -51.254},
            {119.124, 7.28, -182.737},
            {Double.POSITIVE_INFINITY, 15.04, -1107.556},
    };

    /** Indexed by the touchpad speed setting (-7 ~ +7) plus 7. */
    private static final int[] SENSITIVITY_FACTORS =
            {1, 2, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 16, 18, 20};

    static final int MIN_SPEED_SETTING = -7;
    static final int MAX_SPEED_SETTING = 7;

    /** Gestures' output scale: millimetres to 133 DPI pixels. */
    private static final double PIXELS_PER_MM = 133.0 / 25.4;
    private static final double MIN_REASONABLE_DT_S = 0.003;
    private static final double MAX_REASONABLE_DT_S = 0.050;

    private double commonFactor;
    private long lastFrameTimeNs = Long.MIN_VALUE;
    // Kept across gestures, as in the library, which also starts it at 50 ms.
    private double lastReasonableDtS = MAX_REASONABLE_DT_S;
    private final float[] out = new float[2];

    AndroidTouchpadAccel() {
        setSpeedSetting(0);
    }

    /** Android's touchpad pointer speed, -7 (slowest) ~ +7; 0 is the default. */
    void setSpeedSetting(int speed) {
        int clamped = Math.max(MIN_SPEED_SETTING, Math.min(MAX_SPEED_SETTING, speed));
        commonFactor = 0.64 * SENSITIVITY_FACTORS[clamped - MIN_SPEED_SETTING] / 10.0;
    }

    /**
     * Record a frame that carries no cursor motion (finger down, a contact
     * count change) so the next frame's speed is measured from it.
     */
    void markFrame(long eventTimeNs) {
        lastFrameTimeNs = eventTimeNs;
    }

    /**
     * Accelerate one frame of motion.
     *
     * @param dx raw delta on the X axis, in device units
     * @param dy raw delta on the Y axis, in device units
     * @param resolutionX device units per millimetre on X; must be positive
     * @param resolutionY device units per millimetre on Y; must be positive
     * @param eventTimeNs the frame's hardware timestamp
     * @return the cursor delta in display pixels; reused between calls
     */
    float[] accelerate(float dx, float dy, float resolutionX, float resolutionY,
                       long eventTimeNs) {
        double dt = lastFrameTimeNs == Long.MIN_VALUE
                ? -1.0 : (eventTimeNs - lastFrameTimeNs) / 1e9;
        lastFrameTimeNs = eventTimeNs;
        if (dt < MIN_REASONABLE_DT_S || dt > MAX_REASONABLE_DT_S)
            dt = lastReasonableDtS;
        else
            lastReasonableDtS = dt;

        double mmX = dx / resolutionX;
        double mmY = dy / resolutionY;
        double speed = Math.hypot(mmX, mmY) / dt;
        double scale = speed < 0.00001 ? 0.0 : gain(speed) * PIXELS_PER_MM;
        out[0] = (float) (mmX * scale);
        out[1] = (float) (mmY * scale);
        return out;
    }

    /** Output over input speed for a finger moving at {@code speed} mm/s. */
    double gain(double speed) {
        for (double[] seg : SEGMENTS) {
            if (speed <= seg[0])
                return commonFactor * (seg[1] + seg[2] / speed);
        }
        return 0.0;
    }
}
