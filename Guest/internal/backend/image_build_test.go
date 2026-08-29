package backend

import (
	"archive/tar"
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestParseBuildDockerfileSupportsMultipleStages(t *testing.T) {
	plan, err := parseBuildDockerfile([]byte(
		"FROM alpine AS build\nRUN make\nFROM busybox\nCOPY --from=build /out /app\n",
	))
	if err != nil {
		t.Fatalf("parse multi-stage Dockerfile: %v", err)
	}
	if len(plan.stages) != 2 || plan.stages[0].name != "build" {
		t.Fatalf("stages = %#v", plan.stages)
	}
	if got := plan.stages[1].copies[0].from; got != "build" {
		t.Fatalf("COPY source stage = %q", got)
	}
}

func TestParseBuildDockerfileExpandsBuildArguments(t *testing.T) {
	plan, err := parseBuildDockerfileWithArgs([]byte(
		"ARG BASE=alpine\nFROM ${BASE}\nARG VERSION=1\nRUN echo $VERSION\n",
	), map[string]string{"BASE": "busybox", "VERSION": "2"})
	if err != nil {
		t.Fatalf("parse build arguments: %v", err)
	}
	if plan.base != "busybox" {
		t.Fatalf("base = %q, want busybox", plan.base)
	}
	if got := plan.stages[0].runs[0]; got != "echo 2" {
		t.Fatalf("RUN command = %q, want expanded argument", got)
	}
}

func TestParseBuildDockerfilePreservesInstructionOrderAndRunForms(t *testing.T) {
	plan, err := parseBuildDockerfile([]byte(
		"FROM alpine\nENV MARKER=ready\nWORKDIR /app\nCOPY source /app/source\nRUN echo $MARKER\nRUN [\"test\", \"-f\", \"/app/source\"]\n",
	))
	if err != nil {
		t.Fatalf("parse Dockerfile: %v", err)
	}
	instructions := plan.stages[0].instructions
	if len(instructions) != 5 {
		t.Fatalf("instruction count = %d, want 5", len(instructions))
	}
	if instructions[0].kind != "change" || instructions[0].change != "ENV MARKER=ready" {
		t.Fatalf("first instruction = %#v", instructions[0])
	}
	if instructions[3].kind != "run" || instructions[3].run.command != "echo ready" || !instructions[3].run.shell {
		t.Fatalf("shell RUN instruction = %#v", instructions[3])
	}
	if instructions[4].kind != "run" || instructions[4].run.shell || len(instructions[4].run.args) != 3 {
		t.Fatalf("exec-form RUN instruction = %#v", instructions[4])
	}
}

func TestSubstituteBuildVariablesPreservesUnknownRuntimeVariables(t *testing.T) {
	got := substituteBuildVariables("echo $KNOWN $PATH ${UNKNOWN}", map[string]string{"KNOWN": "value"})
	if got != "echo value $PATH ${UNKNOWN}" {
		t.Fatalf("substituted command = %q", got)
	}
}

func TestMergeEnvironmentOverridesExistingKeys(t *testing.T) {
	got := mergeEnvironment(
		[]string{"PATH=/bin", "MARKER=old"},
		[]string{"MARKER=new", "EXTRA=value"},
	)
	want := []string{"PATH=/bin", "MARKER=new", "EXTRA=value"}
	if !equalStrings(got, want) {
		t.Fatalf("merged environment = %#v, want %#v", got, want)
	}
}

func TestApplyBuildEnvironmentExpandsInheritedValues(t *testing.T) {
	environment := []string{"PATH=/bin", "MARKER=old"}
	if err := applyBuildEnvironment(&environment, "PATH=$PATH:/app MARKER=$PATH"); err != nil {
		t.Fatalf("apply build environment: %v", err)
	}
	want := []string{"PATH=/bin:/app", "MARKER=/bin:/app"}
	if !equalStrings(environment, want) {
		t.Fatalf("build environment = %#v, want %#v", environment, want)
	}
}

func TestRewriteBuildArchiveCopiesStageContents(t *testing.T) {
	archive := buildTestTar(t, map[string]string{
		"out":         "",
		"out/app.bin": "built artifact\n",
	})
	result, err := rewriteBuildArchive(archive, "/out", "/app/", false)
	if err != nil {
		t.Fatalf("rewrite stage archive: %v", err)
	}
	entries := readTestTar(t, result)
	if got := string(entries["app/app.bin"]); got != "built artifact\n" {
		t.Fatalf("stage archive entries = %#v", entries)
	}
}

func TestFilterBuildContextAppliesCopyDestination(t *testing.T) {
	contextData := buildTestTar(t, map[string]string{
		"Dockerfile": "FROM alpine\nCOPY app.txt /opt/app.txt\n",
		"app.txt":    "hello from the context\n",
		"ignored":    "must not be copied\n",
	})
	plan, err := parseBuildDockerfile([]byte("FROM alpine\nCOPY app.txt /opt/app.txt\n"))
	if err != nil {
		t.Fatalf("parse Dockerfile: %v", err)
	}

	filtered, err := filterBuildContext(contextData, "Dockerfile", plan.copies)
	if err != nil {
		t.Fatalf("filter context: %v", err)
	}
	entries := readTestTar(t, filtered)
	if got := string(entries["opt/app.txt"]); got != "hello from the context\n" {
		t.Fatalf("copied content = %q, entries = %#v", got, entries)
	}
	if _, ok := entries["ignored"]; ok {
		t.Fatal("unreferenced context file was copied")
	}
}

func TestFilterBuildContextAppliesAddDestination(t *testing.T) {
	contextData := buildTestTar(t, map[string]string{"app.txt": "added content\n"})
	plan, err := parseBuildDockerfile([]byte("FROM alpine\nADD app.txt /srv/app.txt\n"))
	if err != nil {
		t.Fatalf("parse Dockerfile: %v", err)
	}
	filtered, err := filterBuildContext(contextData, "Dockerfile", plan.copies)
	if err != nil {
		t.Fatalf("filter context: %v", err)
	}
	entries := readTestTar(t, filtered)
	if got := string(entries["srv/app.txt"]); got != "added content\n" {
		t.Fatalf("added content = %q", got)
	}
}

func TestAddArchiveExtractsContentsInsteadOfCopyingTheArchive(t *testing.T) {
	inner := buildTestTar(t, map[string]string{
		"bin/tool": "executable\n",
		"README":   "archive readme\n",
	})
	contextData := buildTestTar(t, map[string]string{
		"Dockerfile": "FROM alpine\nADD app.tar /opt/\n",
		"app.tar":    string(inner),
	})
	plan, err := parseBuildDockerfile([]byte("FROM alpine\nADD app.tar /opt/\n"))
	if err != nil {
		t.Fatalf("parse Dockerfile: %v", err)
	}
	filtered, err := filterBuildContext(contextData, "Dockerfile", plan.copies)
	if err != nil {
		t.Fatalf("filter context: %v", err)
	}
	if entries := readTestTar(t, filtered); len(entries) != 0 {
		t.Fatalf("archive source was copied into context: %#v", entries)
	}
	data, found, err := readBuildContextFile(contextData, "app.tar")
	if err != nil || !found {
		t.Fatalf("read archive source: found=%v err=%v", found, err)
	}
	extracted, err := rewriteArchiveContents(data, "/opt/")
	if err != nil {
		t.Fatalf("extract archive: %v", err)
	}
	entries := readTestTar(t, extracted)
	if got := string(entries["opt/bin/tool"]); got != "executable\n" {
		t.Fatalf("extracted tool = %q", got)
	}
	if _, ok := entries["opt/app.tar"]; ok {
		t.Fatal("archive itself was copied")
	}
}

func TestFilterBuildContextCopiesContextRoot(t *testing.T) {
	contextData := buildTestTar(t, map[string]string{
		"Dockerfile": "FROM alpine\nCOPY . /opt/\n",
		"app.txt":    "context file\n",
	})
	plan, err := parseBuildDockerfile([]byte("FROM alpine\nCOPY . /opt/\n"))
	if err != nil {
		t.Fatalf("parse Dockerfile: %v", err)
	}
	filtered, err := filterBuildContext(contextData, "Dockerfile", plan.copies)
	if err != nil {
		t.Fatalf("filter context: %v", err)
	}
	entries := readTestTar(t, filtered)
	if got := string(entries["opt/app.txt"]); got != "context file\n" {
		t.Fatalf("context root copy = %q, entries = %#v", got, entries)
	}
}

func TestFilterBuildContextSupportsWildcardSources(t *testing.T) {
	contextData := buildTestTar(t, map[string]string{
		"one.txt": "one\n",
		"two.log": "two\n",
	})
	plan, err := parseBuildDockerfile([]byte("FROM alpine\nCOPY *.txt /opt/\n"))
	if err != nil {
		t.Fatalf("parse Dockerfile: %v", err)
	}
	filtered, err := filterBuildContext(contextData, "Dockerfile", plan.copies)
	if err != nil {
		t.Fatalf("filter context: %v", err)
	}
	entries := readTestTar(t, filtered)
	if got := string(entries["opt/one.txt"]); got != "one\n" {
		t.Fatalf("wildcard copy = %q, entries = %#v", got, entries)
	}
	if _, ok := entries["opt/two.log"]; ok {
		t.Fatal("wildcard copy included a non-matching file")
	}
}

func TestFilterBuildContextHonorsDockerignorePatterns(t *testing.T) {
	contextData := buildTestTar(t, map[string]string{
		"Dockerfile":    "FROM alpine\nCOPY . /opt/\n",
		".dockerignore": "secret.txt\n!keep.txt\n",
		"secret.txt":    "must be ignored\n",
		"keep.txt":      "must remain\n",
		"app.txt":       "app\n",
	})
	plan, err := parseBuildDockerfile([]byte("FROM alpine\nCOPY . /opt/\n"))
	if err != nil {
		t.Fatalf("parse Dockerfile: %v", err)
	}
	filtered, err := filterBuildContext(contextData, "Dockerfile", plan.copies)
	if err != nil {
		t.Fatalf("filter context: %v", err)
	}
	entries := readTestTar(t, filtered)
	if _, ok := entries["opt/secret.txt"]; ok {
		t.Fatal(".dockerignore pattern was not applied")
	}
	if got := string(entries["opt/keep.txt"]); got != "must remain\n" {
		t.Fatalf("negated .dockerignore pattern = %q", got)
	}
}

func TestFilterBuildContextRejectsMissingSource(t *testing.T) {
	contextData := buildTestTar(t, map[string]string{"Dockerfile": "FROM alpine\n"})
	_, err := filterBuildContext(contextData, "Dockerfile", []buildCopy{{
		sources: []string{"missing.txt"}, destination: "/opt/missing.txt",
	}})
	if err == nil || !strings.Contains(err.Error(), "missing.txt") {
		t.Fatalf("missing source error = %v", err)
	}
}

func TestParseBuildCopyAllowsRemoteADDAndRejectsRemoteCOPY(t *testing.T) {
	copyInstruction, err := parseBuildCopy("https://example.test/app.tar /opt/app.tar", true)
	if err != nil {
		t.Fatalf("remote ADD parse: %v", err)
	}
	if !copyInstruction.remote || len(copyInstruction.sources) != 1 {
		t.Fatalf("remote ADD instruction = %#v", copyInstruction)
	}
	if _, err := parseBuildCopy("https://example.test/app.tar /opt/app.tar", false); err == nil {
		t.Fatal("remote COPY unexpectedly succeeded")
	}
}

func TestDownloadBuildSourceArchivesResponseAtDestination(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		_, _ = writer.Write([]byte("remote content\n"))
	}))
	defer server.Close()
	archive, err := downloadBuildSource(t.Context(), server.URL+"/app.txt", "/srv/")
	if err != nil {
		t.Fatalf("download remote ADD source: %v", err)
	}
	entries := readTestTar(t, archive)
	if got := string(entries["srv/app.txt"]); got != "remote content\n" {
		t.Fatalf("remote ADD archive = %#v", entries)
	}
}

func TestDownloadBuildSourceExtractsRemoteArchive(t *testing.T) {
	inner := buildTestTar(t, map[string]string{"app/main": "remote archive\n"})
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		_, _ = writer.Write(inner)
	}))
	defer server.Close()
	archive, err := downloadBuildSource(t.Context(), server.URL+"/app.tar", "/srv/")
	if err != nil {
		t.Fatalf("download remote archive: %v", err)
	}
	entries := readTestTar(t, archive)
	if got := string(entries["srv/app/main"]); got != "remote archive\n" {
		t.Fatalf("remote archive entries = %#v", entries)
	}
}

func buildTestTar(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var buffer bytes.Buffer
	writer := tar.NewWriter(&buffer)
	for name, contents := range files {
		data := []byte(contents)
		if err := writer.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(data))}); err != nil {
			t.Fatalf("write tar header: %v", err)
		}
		if _, err := writer.Write(data); err != nil {
			t.Fatalf("write tar data: %v", err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("close tar: %v", err)
	}
	return buffer.Bytes()
}

func readTestTar(t *testing.T, data []byte) map[string][]byte {
	t.Helper()
	reader := tar.NewReader(bytes.NewReader(data))
	entries := map[string][]byte{}
	for {
		header, err := reader.Next()
		if err == io.EOF {
			return entries
		}
		if err != nil {
			t.Fatalf("read tar header: %v", err)
		}
		contents, err := io.ReadAll(reader)
		if err != nil {
			t.Fatalf("read tar entry: %v", err)
		}
		entries[header.Name] = contents
	}
}
