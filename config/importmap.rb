# The framework-free browser core, also loaded by the feedback controller.
pin "pocket_kit", to: "pocket_kit/pocket_kit.js"

# Pinned under controllers/ so an app's `eagerLoadControllersFrom("controllers", application)`
# registers each one as `pocket-kit--<name>` with no further setup.
pin "controllers/pocket_kit/feedback_controller", to: "pocket_kit/feedback_controller.js"
