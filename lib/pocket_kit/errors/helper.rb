module PocketKit
  module Errors
    module Helper
      # Meta tags naming the endpoint the page's script posts its errors to and
      # the screen they happen on, or nothing when page errors are off for this
      # request. Put it in <head>.
      def pocket_kit_errors_tag(screen: "#{controller_path}##{action_name}")
        return unless PocketKit.errors.browser && Errors.enabled? && PocketKit.errors.enabled.call(controller)

        safe_join([ tag.meta(name: "pocket-kit-errors", content: pocket_kit.errors_path),
                    tag.meta(name: "pocket-kit-screen", content: screen) ], "\n")
      end
    end
  end
end
