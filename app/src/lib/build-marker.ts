// Which build is live. app/set-marker.sh rewrites this line; because it is a
// source file rather than an environment variable, bumping it genuinely
// invalidates the Docker build cache -- that is what makes the §10 warm-build
// measurement honest, and it is also how the scripts detect that a deploy landed.
export const BUILD_MARKER = "build-1";
