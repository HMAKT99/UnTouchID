import { AbsoluteFill, useCurrentFrame, interpolate, spring, useVideoConfig } from "remotion";

export const Scene1_Problem = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const titleOpacity = interpolate(frame, [0, 20], [0, 1], { extrapolateRight: "clamp" });
  const titleY = spring({ frame, fps, from: 30, to: 0, config: { damping: 12 } });

  const line1Opacity = interpolate(frame, [30, 50], [0, 1], { extrapolateRight: "clamp" });
  const line2Opacity = interpolate(frame, [50, 70], [0, 1], { extrapolateRight: "clamp" });
  const line3Opacity = interpolate(frame, [70, 90], [0, 1], { extrapolateRight: "clamp" });

  const priceOpacity = interpolate(frame, [100, 120], [0, 1], { extrapolateRight: "clamp" });
  const priceScale = spring({ frame: Math.max(0, frame - 100), fps, from: 0.5, to: 1, config: { damping: 8 } });

  return (
    <AbsoluteFill
      style={{
        backgroundColor: "#0a0a1a",
        justifyContent: "center",
        alignItems: "center",
        fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif",
      }}
    >
      {/* Mac Mini icon */}
      <div
        style={{
          fontSize: 80,
          marginBottom: 30,
          opacity: titleOpacity,
          transform: `translateY(${titleY}px)`,
        }}
      >
        🖥️
      </div>

      {/* Title */}
      <div
        style={{
          fontSize: 52,
          fontWeight: 700,
          color: "#ffffff",
          opacity: titleOpacity,
          transform: `translateY(${titleY}px)`,
          textAlign: "center",
        }}
      >
        Your Mac has no Touch ID.
      </div>

      {/* Pain points */}
      <div style={{ marginTop: 40, textAlign: "center" }}>
        <div style={{ fontSize: 28, color: "#888", opacity: line1Opacity, marginBottom: 12 }}>
          🔒 Type password for <span style={{ color: "#ff453a" }}>sudo</span>
        </div>
        <div style={{ fontSize: 28, color: "#888", opacity: line2Opacity, marginBottom: 12 }}>
          🔒 Type password to <span style={{ color: "#ff453a" }}>unlock screen</span>
        </div>
        <div style={{ fontSize: 28, color: "#888", opacity: line3Opacity, marginBottom: 12 }}>
          🔒 Type password for <span style={{ color: "#ff453a" }}>App Store</span>
        </div>
      </div>

      {/* Apple's price tag */}
      <div
        style={{
          marginTop: 40,
          opacity: priceOpacity,
          transform: `scale(${priceScale})`,
          fontSize: 32,
          color: "#ff9500",
          fontWeight: 600,
        }}
      >
        Apple's fix: Magic Keyboard for <span style={{ color: "#ff453a", fontSize: 42 }}>$199</span>
      </div>
    </AbsoluteFill>
  );
};
