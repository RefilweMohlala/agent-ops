
// Structured JSON logs. Lines with an "_aws" block become CloudWatch metrics
// automatically (Embedded Metric Format), so no extra SDK calls are needed.
function unitFor(name) {
  if (name.endsWith("Ms")) return "Milliseconds";
  if (name.endsWith("USD")) return "None";
  return "Count";
}

export function emit(metrics, { dimensions = {}, props = {} } = {}) {
  const dims = { Env: process.env.ENV ?? "local", ...dimensions };
  console.log(
    JSON.stringify({
      _aws: {
        Timestamp: Date.now(),
        CloudWatchMetrics: [
          {
            Namespace: "AgentOps",
            Dimensions: [Object.keys(dims)],
            Metrics: Object.keys(metrics).map((name) => ({ Name: name, Unit: unitFor(name) })),
          },
        ],
      },
      ...props,
      ...dims,
      ...metrics,
    }),
  );
}

export function log(level, message, props = {}) {
  console.log(JSON.stringify({ level, message, env: process.env.ENV, ...props }));
}