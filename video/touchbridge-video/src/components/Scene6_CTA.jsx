import { AbsoluteFill, useCurrentFrame, interpolate, spring, useVideoConfig } from "remotion";

export const Scene6_CTA = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const logoScale = spring({ frame, fps, from: 0, to: 1, config: { damping: 10 } });
  const titleOpacity = interpolate(frame, [10, 25], [0, 1], { extrapolateRight: "clamp" });
  const cmdOpacity = interpolate(frame, [30, 45], [0, 1], { extrapolateRight: "clamp" });
  const taglineOpacity = interpolate(frame, [50, 65], [0, 1], { extrapolateRight: "clamp" });

  // Pulsing glow effect
  const glowOpacity = interpolate(frame, [0, 45, 90], [0.3, 0.6, 0.3]);

  return (
    <AbsoluteFill
      style={{
        backgroundColor: "#0a0a1a",
        justifyContent: "center",
        alignItems: "center",
        fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif",
      }}
    >
      {/* Background glow */}
      <div
        style={{
          position: "absolute",
          width: 400,
          height: 400,
          borderRadius: "50%",
          background: "radial-gradient(circle, rgba(43,112,251,0.3) 0%, transparent 70%)",
          opacity: glowOpacity,
        }}
      />

      {/* Logo */}
      <div style={{ fontSize: 80, transform: `scale(${logoScale})`, marginBottom: 16 }}>🔐</div>

      {/* Title */}
      <div style={{ fontSize: 52, fontWeight: 800, color: "#fff", opacity: titleOpacity, letterSpacing: -1 }}>
        TouchBridge
      </div>

      {/* Command */}
      <div
        style={{
          marginTop: 24,
          opacity: cmdOpacity,
          backgroundColor: "#1a1a2e",
          borderRadius: 12,
          padding: "14px 32px",
          fontFamily: "'SF Mono', 'Menlo', monospace",
          fontSize: 20,
          color: "#30d158",
        }}
      >
        git clone github.com/HMAKT99/UnTouchID
      </div>

      {/* Tagline */}
      <div
        style={{
          marginTop: 32,
          opacity: taglineOpacity,
          fontSize: 24,
          color: "#888",
          textAlign: "center",
        }}
      >
        Stop typing your password. Use your fingerprint.
      </div>

      {/* Badges */}
      <div
        style={{
          marginTop: 20,
          opacity: taglineOpacity,
          display: "flex",
          gap: 16,
          fontSize: 14,
          color: "#666",
        }}
      >
        <span>Free</span>
        <span>·</span>
        <span>Open Source</span>
        <span>·</span>
        <span>MIT License</span>
        <span>·</span>
        <span>91 Tests</span>
      </div>
    </AbsoluteFill>
  );
};
