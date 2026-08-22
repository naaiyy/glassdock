package backend

import (
	"testing"
	"time"

	containerimages "github.com/containerd/containerd/v2/core/images"
	imagespec "github.com/opencontainers/image-spec/specs-go/v1"

	"github.com/glassdock/glassdock/guest/internal/api"
)

func TestApplyCommitChangesUpdatesImageConfiguration(t *testing.T) {
	t.Parallel()
	image := imagespec.Image{
		Config: imagespec.ImageConfig{
			Env:    []string{"A=old"},
			Labels: map[string]string{"role": "old"},
		},
	}

	onBuild := []string{}
	err := applyCommitChangesWithOnBuild(&image, "CMD [\"/bin/sh\",\"-c\",\"echo ok\"]\nENV A=new B=two\nLABEL role=web\nEXPOSE 8080/tcp\nVOLUME /data\nUSER 1000\nWORKDIR /app\nSTOPSIGNAL SIGTERM\nONBUILD RUN echo ready", &onBuild)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := image.Config.Cmd, []string{"/bin/sh", "-c", "echo ok"}; !equalStrings(got, want) {
		t.Fatalf("got command %#v, want %#v", got, want)
	}
	if got, want := image.Config.Env, []string{"A=new", "B=two"}; !equalStrings(got, want) {
		t.Fatalf("got environment %#v, want %#v", got, want)
	}
	if image.Config.Labels["role"] != "web" {
		t.Fatalf("configuration changes were not applied: %#v", image.Config)
	}
	if _, ok := image.Config.ExposedPorts["8080/tcp"]; !ok {
		t.Fatalf("exposed port was not applied: %#v", image.Config.ExposedPorts)
	}
	if _, ok := image.Config.Volumes["/data"]; !ok || image.Config.User != "1000" || image.Config.WorkingDir != "/app" || image.Config.StopSignal != "SIGTERM" {
		t.Fatalf("configuration changes were not applied: %#v", image.Config)
	}
	if got, want := onBuild, []string{"RUN echo ready"}; !equalStrings(got, want) {
		t.Fatalf("got ONBUILD instructions %#v, want %#v", got, want)
	}
}

func TestApplyCommitChangesUsesShellFormForCommands(t *testing.T) {
	t.Parallel()
	image := imagespec.Image{}
	if err := applyCommitChanges(&image, "CMD echo hello"); err != nil {
		t.Fatal(err)
	}
	if got, want := image.Config.Cmd, []string{"/bin/sh", "-c", "echo hello"}; !equalStrings(got, want) {
		t.Fatalf("got command %#v, want %#v", got, want)
	}
}

func TestApplyCommitChangesStoresDockerHealthcheckExtras(t *testing.T) {
	t.Parallel()
	extras := dockerConfigExtras{}
	if err := applyCommitChangesWithExtras(
		&imagespec.Image{},
		"HEALTHCHECK --interval=5s --timeout=2s --retries=4 CMD true",
		nil,
		&extras,
	); err != nil {
		t.Fatal(err)
	}
	if extras.Healthcheck == nil {
		t.Fatal("healthcheck was not stored")
	}
	if got, want := extras.Healthcheck.Test, []string{"CMD-SHELL", "true"}; !equalStrings(got, want) {
		t.Fatalf("got healthcheck test %#v, want %#v", got, want)
	}
	if extras.Healthcheck.Interval != int64(5*time.Second) ||
		extras.Healthcheck.Timeout != int64(2*time.Second) || extras.Healthcheck.Retries != 4 {
		t.Fatalf("got healthcheck options %#v", extras.Healthcheck)
	}
}

func TestApplyCommitChangesRejectsFilesystemInstructions(t *testing.T) {
	t.Parallel()
	for _, instruction := range []string{"RUN touch /tmp/file", "COPY file /", "HEALTHCHECK CMD true"} {
		if err := applyCommitChanges(&imagespec.Image{}, instruction); err == nil {
			t.Fatalf("expected %q to be rejected", instruction)
		}
	}
}

func TestDockerOnBuildRoundTrip(t *testing.T) {
	t.Parallel()
	data := []byte(`{"config":{"Cmd":["sh"],"OnBuild":["RUN echo base"]}}`)
	values, err := dockerOnBuild(data)
	if err != nil {
		t.Fatal(err)
	}
	values = append(values, "COPY app /app")
	encoded, err := encodeDockerOnBuild(data, values)
	if err != nil {
		t.Fatal(err)
	}
	got, err := dockerOnBuild(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"RUN echo base", "COPY app /app"}; !equalStrings(got, want) {
		t.Fatalf("got ONBUILD %#v, want %#v", got, want)
	}
}

func TestCommitLayerMediaTypeMatchesSourceFormat(t *testing.T) {
	t.Parallel()
	if got := commitLayerMediaType(imagespec.Manifest{MediaType: containerimages.MediaTypeDockerSchema2Manifest}); got != containerimages.MediaTypeDockerSchema2Layer {
		t.Fatalf("got Docker layer media type %q", got)
	}
	if got := commitLayerMediaType(imagespec.Manifest{MediaType: imagespec.MediaTypeImageManifest}); got != imagespec.MediaTypeImageLayer {
		t.Fatalf("got OCI layer media type %q", got)
	}
}

func TestCommitImageNameDefaultsToLatestOrGeneratedTag(t *testing.T) {
	t.Parallel()
	if got := commitImageName(api.ImageCommitRequest{Repository: "example.test/app"}, "sha256:abc"); got != "example.test/app:latest" {
		t.Fatalf("got default repository name %q", got)
	}
	if got := commitImageName(api.ImageCommitRequest{}, "sha256:abc"); got != "glassdock/commit:abc" {
		t.Fatalf("got generated repository name %q", got)
	}
}

func equalStrings(got, want []string) bool {
	if len(got) != len(want) {
		return false
	}
	for index := range got {
		if got[index] != want[index] {
			return false
		}
	}
	return true
}
