import { AbsoluteFill, useCurrentFrame, interpolate, spring, useVideoConfig } from "remotion";

export const Scene4_Devices = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const titleOpacity = interpolate(frame, [0, 20], [0, 1], { extrapolateRight: "clamp" });

  const devices = [
    { icon: "📱", name: "iPhone", detail: "Face ID", delay: 20 },
    { icon: "🤖", name: "Android", detail: "Fingerprint", delay: 35 },
    { icon: "⌚", name: "Apple Watch", detail: "Tap", delay: 50 },
    { icon: "⌚", name: "Wear OS", detail: "Tap", delay: 65 },
    { icon: "🌐", name: "Any Browser", detail: "No app needed", delay: 80 },
    { icon: "🖥️", name: "Simulator", detail: "No device needed", delay: 95 },
  ];

  return (
    <AbsoluteFill
      style={{
        backgroundColor: "#0a0a1a",
        justifyContent: "center",
        alignItems: "center",
        fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif",
      }}
    >
      <div
        style={{
          fontSize: 42,
          fontWeight: 700,
          color: "#fff",
          opacity: titleOpacity,
          marginBottom: 50,
        }}
      >
        Works with every device
      </div>

      <div
        style={{
          display: "flex",
          flexWrap: "wrap",
          justifyContent: "center",
          gap: 24,
          maxWidth: 1200,
        }}
      >
        {devices.map((device, i) => {
          const scale = spring({
            frame: Math.max(0, frame - device.delay),
            fps,
            from: 0,
            to: 1,
            config: { damping: 10 },
          });

          return (
            <div
              key={i}
              style={{
                width: 180,
                padding: "28px 20px",
                backgroundColor: "#1a1a2e",
                borderRadius: 16,
                textAlign: "center",
                transform: `scale(${scale})`,
              }}
            >
              <div style={{ fontSize: 48, marginBottom: 12 }}>{device.icon}</div>
              <div style={{ fontSize: 20, fontWeight: 600, color: "#fff", marginBottom: 4 }}>
                {device.name}
              </div>
              <div style={{ fontSize: 14, color: "#888" }}>{device.detail}</div>
            </div>
          );
        })}
      </div>
    </AbsoluteFill>
  );
};
