# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "yaml"

class ImagePublishingTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_image_variables_and_manifest_use_the_calling_repository
    action = YAML.load_file(File.join(ROOT, ".github/actions/build-and-publish-image/action.yml"))
    steps = action.fetch("runs").fetch("steps")
    variables = steps.find { |step| step["name"] == "Set image variables" }
    manifest = steps.find { |step| step["name"] == "Create and push multi-arch manifest" }
    build = steps.find { |step| step["name"] == "Pre-build Dev Container Image" }.fetch("with")

    assert_equal "${{ env.IMAGE_NAME }}", build.fetch("imageName")
    assert_equal "${{ env.IMAGE_NAME }}:${{ inputs.ruby_version }}-${{ inputs.platform_suffix }}", build.fetch("cacheFrom")

    Dir.mktmpdir do |dir|
      output = File.join(dir, "env")
      _, stderr, status = Open3.capture3(
        { "GITHUB_REPOSITORY" => "Example/My-Fork", "IMAGE_TAG" => "ruby-2.3.7", "GITHUB_ENV" => output },
        "bash", "-e", "-c", variables.fetch("run")
      )
      assert status.success?, stderr
      env = File.readlines(output, chomp: true).to_h { |line| line.split("=", 2) }
      assert_equal "2.3.7", env.fetch("IMAGE_VERSION")
      assert_equal "ghcr.io/example/my-fork/images/ruby", env.fetch("IMAGE_NAME")

      docker = File.join(dir, "docker")
      File.write(docker, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n")
      File.chmod(0o755, docker)
      stdout, stderr, status = Open3.capture3(
        env.merge("PATH" => "#{dir}:#{ENV.fetch("PATH")}", "RUBY_VERSION" => "3.4.13"),
        "bash", "-e", "-c", manifest.fetch("run")
      )
      assert status.success?, stderr
      assert_equal [
        "buildx", "imagetools", "create",
        "-t", "ghcr.io/example/my-fork/images/ruby:2.3.7-3.4.13",
        "-t", "ghcr.io/example/my-fork/images/ruby:3.4.13",
        "ghcr.io/example/my-fork/images/ruby:2.3.7-3.4.13-amd64",
        "ghcr.io/example/my-fork/images/ruby:2.3.7-3.4.13-arm64"
      ], stdout.lines.map(&:chomp)
    end
  end

  def test_image_uses_tagged_ruby_feature_and_distribution_git
    config_dir = File.join(ROOT, "images/ruby/.devcontainer")
    json = File.read(File.join(config_dir, "devcontainer.json")).lines.reject { |line| line.lstrip.start_with?("//") }.join
    features = JSON.parse(json).fetch("features")
    ruby_path = features.keys.find { |key| key.start_with?(".") }

    assert_equal File.join(ROOT, "features/src/ruby"), File.realpath(File.join(config_dir, ruby_path))
    assert File.file?(File.join(config_dir, ruby_path, "devcontainer-feature.json"))
    assert_equal "os-provided", features.fetch("ghcr.io/devcontainers/features/git:1").fetch("version")
  end

  def test_release_workflows_target_the_repository
    tag_workflow = YAML.load_file(File.join(ROOT, ".github/workflows/publish-new-image-version.yaml"))
    assert_includes tag_workflow.fetch("on").fetch("push").fetch("tags"), "ruby-*.*.*"

    workflow = YAML.load_file(File.join(ROOT, ".github/workflows/release-features.yaml"))
    steps = workflow.fetch("jobs").fetch("deploy").fetch("steps")
    namespace_step = steps.find { |step| step["name"] == "Set feature namespace" }
    publish_step = steps.find { |step| step["name"] == "Publish" }
    assert_equal "${{ env.FEATURES_NAMESPACE }}", publish_step.fetch("with").fetch("features-namespace")

    Dir.mktmpdir do |dir|
      output = File.join(dir, "env")
      _, stderr, status = Open3.capture3(
        { "GITHUB_REPOSITORY" => "Example/My-Fork", "GITHUB_ENV" => output },
        "bash", "-e", "-c", namespace_step.fetch("run")
      )
      assert status.success?, stderr
      assert_equal "FEATURES_NAMESPACE=example/my-fork/features\n", File.read(output)
    end
  end
end
