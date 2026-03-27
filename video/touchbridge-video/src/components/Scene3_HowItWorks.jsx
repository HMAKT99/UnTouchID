import { AbsoluteFill, useCurrentFrame, interpolate, spring, useVideoConfig } from "remotion";

export const Scene3_HowItWorks = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const titleOpacity = interpolate(frame, [0, 20], [0, 1], { extrapolateRight: "clamp" });

  const steps = [
    { text: "sudo echo test", icon: "💻", delay: 30 },
    { text: "PAM module connects to daemon", icon: "🔌", delay: 60 },
    { text: "Daemon sends nonce via BLE", icon: "📡", delay: 90 },
    { text: "Phone prompts Face ID", icon: "📱", delay: 120 },
    { text: "Secure Enclave signs nonce", icon: "🔐", delay: 150 },
    { text: "Daemon verifies → sudo succeeds", icon: "✅", delay: 180 },
  ];

  // Animated arrow between Mac and Phone
  const arrowProgress = interpolate(frame, [90, 130], [0, 1], { extrapolateRight: "clamp" });
  const arrowBack = interpolate(frame, [150, 180], [0, 1], { extrapolateRight: "clamp" });

  return (
    <AbsoluteFill
      style={{
        backgroundColor: "#0a0a1a",
        fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif",
        padding: 80,
      }}
    >
      {/* Title */}
      <div
        style={{
          fontSize: 42,
          fontWeight: 700,
          color: "#fff",
          opacity: titleOpacity,
          textAlign: "center",
          marginBottom: 50,
        }}
      >
        How It Works
      </div>

      {/* Diagram */}
      <div
        style={{
          display: "flex",
          justifyContent: "center",
          alignItems: "center",
          gap: 80,
          marginBottom: 50,
        }}
      >
        {/* Mac */}
        <div style={{ textAlign: "center" }}>
          <div style={{ fontSize: 64 }}>🖥️</div>
          <div style={{ color: "#888", fontSize: 18, marginTop: 8 }}>Your Mac</div>
        </div>

        {/* Arrow */}
        <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 8 }}>
          <div style={{ color: "#30d158", fontSize: 16, opacity: arrowProgress }}>
            challenge →
          </div>
          <div
            style={{
              width: 200,
              height: 3,
              background: `linear-gradient(90deg, #30d158 ${arrowProgress * 100}%, #333 ${arrowProgress * 100}%)`,
              borderRadius: 2,
            }}
          />
          <div
            style={{
              width: 200,
              height: 3,
              background: `linear-gradient(270deg, #2b70fb ${arrowBack * 100}%, #333 ${arrowBack * 100}%)`,
              borderRadius: 2,
            }}
          />
          <div style={{ color: "#2b70fb", fontSize: 16, opacity: arrowBack }}>
            ← signed response
          </div>
        </div>

        {/* Phone */}
        <div style={{ textAlign: "center" }}>
          <div style={{ fontSize: 64 }}>📱</div>
          <div style={{ color: "#888", fontSize: 18, marginTop: 8 }}>Your Phone</div>
        </div>
      </div>

      {/* Steps */}
      <div style={{ display: "flex", flexDirection: "column", gap: 10, maxWidth: 700, margin: "0 auto" }}>
        {steps.map((step, i) => {
          const opacity = interpolate(frame, [step.delay, step.delay + 15], [0, 1], {
            extrapolateRight: "clamp",
          });
          const x = spring({
            frame: Math.max(0, frame - step.delay),
            fps,
            from: 30,
            to: 0,
            config: { damping: 12 },
          });

          return (
            <div
              key={i}
              style={{
                display: "flex",
                alignItems: "center",
                gap: 16,
                opacity,
                transform: `translateX(${x}px)`,
                fontSize: 20,
                color: "#ccc",
              }}
            >
              <span style={{ fontSize: 24 }}>{step.icon}</span>
              <span>{step.text}</span>
            </div>
          );
        })}
      </div>
    </AbsoluteFill>
  );
};
