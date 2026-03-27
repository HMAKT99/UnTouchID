import { AbsoluteFill, useCurrentFrame, interpolate, spring, useVideoConfig } from "remotion";

export const Scene2_Solution = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const logoScale = spring({ frame, fps, from: 0, to: 1, config: { damping: 10 } });
  const titleOpacity = interpolate(frame, [15, 35], [0, 1], { extrapolateRight: "clamp" });
  const subtitleOpacity = interpolate(frame, [40, 60], [0, 1], { extrapolateRight: "clamp" });

  const termLine1 = interpolate(frame, [70, 75], [0, 1], { extrapolateRight: "clamp" });
  const termLine2 = interpolate(frame, [85, 90], [0, 1], { extrapolateRight: "clamp" });
  const termLine3 = interpolate(frame, [100, 105], [0, 1], { extrapolateRight: "clamp" });
  const checkmark = interpolate(frame, [115, 125], [0, 1], { extrapolateRight: "clamp" });
  const checkScale = spring({ frame: Math.max(0, frame - 115), fps, from: 0, to: 1, config: { damping: 8 } });

  return (
    <AbsoluteFill
      style={{
        backgroundColor: "#0a0a1a",
        justifyContent: "center",
        alignItems: "center",
        fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif",
      }}
    >
      {/* Logo */}
      <div style={{ fontSize: 72, transform: `scale(${logoScale})`, marginBottom: 10 }}>
        🔐
      </div>

      {/* Title */}
      <div
        style={{
          fontSize: 56,
          fontWeight: 800,
          color: "#ffffff",
          opacity: titleOpacity,
          letterSpacing: -1,
        }}
      >
        TouchBridge
      </div>

      {/* Subtitle */}
      <div
        style={{
          fontSize: 26,
          color: "#30d158",
          opacity: subtitleOpacity,
          marginTop: 8,
          fontWeight: 500,
        }}
      >
        Use your phone's fingerprint. Free. Open source.
      </div>

      {/* Terminal demo */}
      <div
        style={{
          marginTop: 50,
          backgroundColor: "#1a1a2e",
          borderRadius: 16,
          padding: "24px 40px",
          fontFamily: "'SF Mono', 'Menlo', monospace",
          fontSize: 22,
          minWidth: 600,
        }}
      >
        <div style={{ opacity: termLine1, color: "#888", marginBottom: 8 }}>
          <span style={{ color: "#30d158" }}>$</span> sudo echo hello
        </div>
        <div style={{ opacity: termLine2, color: "#ff9f0a", marginBottom: 8 }}>
          → Phone buzzes → Touch fingerprint
        </div>
        <div style={{ opacity: checkmark, transform: `scale(${checkScale})`, color: "#30d158" }}>
          ✓ Authenticated
        </div>
      </div>
    </AbsoluteFill>
  );
};
