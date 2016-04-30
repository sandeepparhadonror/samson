require_relative "../../test_helper"

SingleCov.covered!

describe Kubernetes::DeployExecutor do
  let(:output) { StringIO.new }
  let(:out) { output.string }
  let(:stage) { deploy.stage }
  let(:deploy) { job.deploy }
  let(:job) { jobs(:succeeded_test) }
  let(:build) { builds(:docker_build) }
  let(:executor) { Kubernetes::DeployExecutor.new(output, job: job) }

  before do
    stage.update_column :kubernetes, true
    deploy.update_column :kubernetes, true
  end

  describe "#pid" do
    it "returns a fake pid" do
      executor.pid.must_include "Kubernetes"
    end
  end

  describe "#execute!" do
    def execute!
      stub_request(:get, %r{http://foobar.server/api/1/namespaces/staging/pods}).to_return(body: pod_reply.to_json) # checks pod status to see if it's good
      executor.execute!
    end

    def stop_after_first_iteration
      executor.expects(:sleep).with { executor.stop!('FAKE-SGINAL'); true }
    end

    let(:pod_reply) do
      {
        resourceVersion: "1",
        items: [{
          status: {
            phase: "Running", conditions: [{type: "Ready", status: "True"}],
            containerStatuses: [{restartCount: 0}]
          }
        }]
      }
    end
    let(:pod_status) { pod_reply[:items].first[:status] }

    before do
      job.update_column(:commit, build.git_sha) # this is normally done by JobExecution
      Kubernetes::ReleaseDoc.any_instance.stubs(raw_template: {'kind' => 'Deployment', 'spec' => {'template' => {'metadata' => {'labels' => {}}, 'spec' => {'containers' => [{}]}}}, 'metadata' => {'labels' => {}}}.to_yaml) # TODO: should inject that from current checkout and not fetch via github
      Kubernetes::Cluster.any_instance.stubs(connection_valid?: true, namespace_exists?: true)
      stage.deploy_groups.each do |dg|
        dg.create_cluster_deploy_group cluster: kubernetes_clusters(:test_cluster), namespace: 'staging', deploy_group: dg
      end
      stub_request(:get, "http://foobar.server/apis/extensions/v1beta1/namespaces/staging/deployments/").to_return(status: 404) # checks for previous deploys ... but there are none
      stub_request(:post, "http://foobar.server/apis/extensions/v1beta1/namespaces/staging/deployments").to_return(body: "{}") # creates deployment
      executor.stubs(:sleep)
    end

    it "succeeds" do
      assert execute!
      out.must_include "resque_worker: Live\n"
      out.must_include "SUCCESS"
    end

    describe "build" do
      before do
        build.update_column(:docker_repo_digest, nil)
      end

      it "fails when the build is not built" do
        e = assert_raises Samson::Hooks::UserError do
          execute!
        end
        e.message.must_equal "Build #{build.url} was created but never ran, run it manually."
        out.wont_include "Creating Build"
      end

      it "waits when build is running" do
        build.create_docker_job.update_column(:status, 'running')
        build.save!

        job = build.docker_build_job

        Build.any_instance.stubs(:docker_build_job).with do |reload|
          if reload # inside wait loop
            job.status = 'succeeded'
            build.update_column(:docker_repo_digest, 'somet-digest')
          end
          true
        end.returns job

        assert execute!

        out.must_include "Waiting for Build #{build.url} to finish."
        out.must_include "SUCCESS"
      end

      it "fails when build job failed" do
        build.create_docker_job.update_column(:status, 'cancelled')
        build.save!
        e = assert_raises Samson::Hooks::UserError do
          execute!
        end
        e.message.must_equal "Build #{build.url} is cancelled, rerun it manually."
        out.wont_include "Creating Build"
      end

      describe "when build needs to be created" do
        before do
          build.update_column(:git_sha, 'something-else')
          Build.any_instance.stubs(:validate_git_reference)
        end

        it "succeeds when the build works" do
          DockerBuilderService.any_instance.expects(:run!).with do
            Build.last.create_docker_job.update_column(:status, 'succeeded')
            Build.last.update_column(:docker_repo_digest, 'some-sha')
            true
          end
          assert execute!
          out.must_include "SUCCESS"
          out.must_include "Creating Build for #{job.commit}"
          out.must_include "Build #{Build.last.url} is looking good"
        end

        it "fails when the build fails" do
          DockerBuilderService.any_instance.expects(:run!).with do
            Build.any_instance.expects(:docker_build_job).at_least_once.returns Job.new(status: 'cancelled')
            true
          end
          e = assert_raises Samson::Hooks::UserError do
            execute!
          end
          e.message.must_equal "Build #{Build.last.url} is cancelled, rerun it manually."
          out.must_include "Creating Build for #{job.commit}.\n"
        end

        it "stops when deploy is stopped by user" do
          executor.stop!('FAKE-SIGNAL')
          DockerBuilderService.any_instance.expects(:run!).returns(true)
          refute execute!
          out.scan(/.*Build.*/).must_equal ["Creating Build for #{job.commit}."] # not waiting for build
          out.must_include "STOPPED"
        end
      end
    end

    it "stops the loop when stopping" do
      executor.stop!('FAKE-SIGNAL')
      refute execute!
      out.wont_include "SUCCESS"
      out.must_include "STOPPED"
    end

    it "waits when deploy is not running" do
      pod_status[:phase] = "Pending"
      pod_status.delete(:conditions)

      stop_after_first_iteration
      refute execute!

      out.must_include "resque_worker: Waiting (Pending, not Ready)\n"
      out.must_include "STOPPED"
    end

    it "waits when deploy is running but not ready" do
      pod_status[:conditions][0][:status] = "False"

      stop_after_first_iteration
      refute execute!

      out.must_include "resque_worker: Waiting (Running, not Ready)\n"
      out.must_include "STOPPED"
    end

    it "fails when release has errors" do
      Kubernetes::Release.any_instance.expects(:persisted?).at_least_once.returns(false)
      e = assert_raises Samson::Hooks::UserError do
        execute!
      end
      e.message.must_equal "Failed to create release: []" # inspected errros
    end

    it "fails when pod is failing to boot" do
      pod_status[:containerStatuses][0][:restartCount] = 1
      executor.instance_variable_set(:@testing_for_stability, 0)
      refute execute!
      out.must_include "resque_worker: Restarted"
      out.must_include "UNSTABLE - service is restarting"
    end

    # not sure if this will ever happen ...
    it "shows error when pod could not be found" do
      pod_reply[:items].clear

      stop_after_first_iteration
      refute execute!

      out.must_include "resque_worker: Missing\n"
      out.must_include "STOPPED"
    end
  end
end
