package backend

import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"strconv"
	"strings"
	"time"

	"github.com/glassdock/glassdock/guest/internal/api"
)

const (
	maxBuildContextBytes = 64 * 1024 * 1024
	maxDockerfileBytes   = 1 * 1024 * 1024
)

type buildPlan struct {
	stages  []buildStage
	base    string
	changes []string
	runs    []string
	copies  []buildCopy
}

type buildStage struct {
	base         string
	name         string
	shell        []string
	changes      []string
	runs         []string
	copies       []buildCopy
	instructions []buildInstruction
}

type buildInstruction struct {
	change string
	copy   buildCopy
	run    buildRun
	kind   string
}

type buildRun struct {
	command string
	args    []string
	shell   bool
}

type buildStageState struct {
	env   []string
	cwd   string
	user  string
	shell []string
}

type buildCopy struct {
	sources     []string
	destination string
	from        string
	remote      bool
	add         bool
}

// Build executes the Dockerfile instructions that can be represented by the
// guest containerd runtime. The build context is applied to a temporary
// container root, RUN instructions execute through the guest exec path, and
// the final root is committed as a normal containerd image.
func (b *Backend) Build(ctx context.Context, request api.ImageBuildRequest) (api.ImageResponse, error) {
	if len(request.Context) == 0 {
		return api.ImageResponse{}, errors.New("build context is empty")
	}
	if len(request.Context) > maxBuildContextBytes {
		return api.ImageResponse{}, fmt.Errorf("build context exceeds %d bytes", maxBuildContextBytes)
	}
	dockerfile := request.Dockerfile
	if dockerfile == "" {
		dockerfile = "Dockerfile"
	}
	dockerfileData, err := readBuildFile(request.Context, dockerfile)
	if err != nil {
		return api.ImageResponse{}, err
	}
	plan, err := parseBuildDockerfileWithArgs(dockerfileData, request.BuildArgs)
	if err != nil {
		return api.ImageResponse{}, err
	}
	if len(plan.stages) == 0 || plan.base == "" {
		return api.ImageResponse{}, errors.New("Dockerfile does not contain a FROM instruction")
	}

	keepAlive := []string{"/bin/sh", "-c", "while :; do sleep 3600; done"}
	stageContainers := make([]string, len(plan.stages))
	stageNames := make(map[string]string, len(plan.stages))
	cleanupIDs := make([]string, 0, len(plan.stages))
	defer func() {
		for _, id := range cleanupIDs {
			_ = b.Delete(context.Background(), api.ContainerDeleteRequest{ID: id, Force: true})
		}
	}()

	for stageIndex, stage := range plan.stages {
		base, err := b.Pull(ctx, api.ImagePullRequest{
			Reference: stage.base, Snapshotter: "overlayfs",
		})
		if err != nil {
			return api.ImageResponse{}, fmt.Errorf("pull build base image %q: %w", stage.base, err)
		}
		baseDetails, err := b.Image(ctx, base.Name)
		if err != nil {
			return api.ImageResponse{}, fmt.Errorf("inspect build base image %q: %w", stage.base, err)
		}
		state := buildStageState{
			env:   append([]string(nil), baseDetails.Config.Env...),
			cwd:   baseDetails.Config.WorkingDir,
			user:  baseDetails.Config.User,
			shell: append([]string(nil), baseDetails.Config.Shell...),
		}
		if len(state.shell) == 0 {
			state.shell = []string{"/bin/sh", "-c"}
		}
		id := fmt.Sprintf("glassdock-build-%d-%d", time.Now().UnixNano(), stageIndex)
		if _, err := b.Create(ctx, api.ContainerCreateRequest{
			ID: id, Image: base.Name, Cmd: &keepAlive,
		}); err != nil {
			return api.ImageResponse{}, fmt.Errorf("create build stage %d: %w", stageIndex, err)
		}
		cleanupIDs = append(cleanupIDs, id)
		stageContainers[stageIndex] = id
		if stage.name != "" {
			stageNames[strings.ToLower(stage.name)] = id
		}

		started := false
		for instructionIndex, instruction := range stage.instructions {
			switch instruction.kind {
			case "copy":
				copyInstruction := instruction.copy
				copyInstruction.destination = substituteBuildVariables(
					copyInstruction.destination, buildEnvironmentVariables(state.env),
				)
				for index, source := range copyInstruction.sources {
					copyInstruction.sources[index] = substituteBuildVariables(
						source, buildEnvironmentVariables(state.env),
					)
				}
				if err := applyBuildCopy(
					ctx, b, request.Context, dockerfile, id, copyInstruction, state.cwd,
					stageIndex, stageContainers, stageNames, &cleanupIDs,
				); err != nil {
					return api.ImageResponse{}, fmt.Errorf(
						"apply Dockerfile copy at stage %d instruction %d: %w",
						stageIndex, instructionIndex, err,
					)
				}
			case "change":
				if err := applyBuildStageChange(ctx, b, id, &state, instruction.change); err != nil {
					return api.ImageResponse{}, fmt.Errorf(
						"apply Dockerfile change at stage %d instruction %d: %w",
						stageIndex, instructionIndex, err,
					)
				}
			case "run":
				if !started {
					if _, err := b.Start(ctx, api.ContainerStartRequest{ID: id}); err != nil {
						return api.ImageResponse{}, fmt.Errorf("start build stage %d: %w", stageIndex, err)
					}
					started = true
				}
				execArgs := append([]string(nil), instruction.run.args...)
				environment := buildEnvironmentVariables(state.env)
				if instruction.run.shell {
					command := substituteBuildVariables(instruction.run.command, environment)
					execArgs = append(append([]string(nil), state.shell...), command)
				} else {
					for index, argument := range execArgs {
						execArgs[index] = substituteBuildVariables(argument, environment)
					}
				}
				exitCode, err := b.Exec(ctx, api.ContainerExecRequest{
					ID: id, ExecID: fmt.Sprintf("%s-run-%d", id, instructionIndex),
					Args: execArgs, Env: append([]string(nil), state.env...), Cwd: state.cwd, User: state.user,
				}, func(string, []byte) error { return nil })
				if err != nil {
					return api.ImageResponse{}, fmt.Errorf("run Dockerfile command %q: %w", instruction.run.command, err)
				}
				if exitCode != 0 {
					return api.ImageResponse{}, fmt.Errorf(
						"Dockerfile command %q exited with code %d", instruction.run.command, exitCode,
					)
				}
			}
		}
		if started {
			if err := b.Kill(ctx, id, 9); err != nil {
				return api.ImageResponse{}, fmt.Errorf("stop build stage %d: %w", stageIndex, err)
			}
			if _, _, err := b.Wait(ctx, id); err != nil {
				return api.ImageResponse{}, fmt.Errorf("wait for build stage %d: %w", stageIndex, err)
			}
		}
	}
	targets := append([]string(nil), request.Tags...)
	if len(targets) == 0 {
		targets = []string{"glassdock/build:latest"}
	}
	repository, tag := splitBuildTag(targets[0])
	image, err := b.CommitImage(ctx, api.ImageCommitRequest{
		Container:  stageContainers[len(stageContainers)-1],
		Repository: repository,
		Tag:        tag,
		Changes:    strings.Join(plan.stages[len(plan.stages)-1].changes, "\n"),
		Comment:    "glassdock build",
	})
	if err != nil {
		return api.ImageResponse{}, fmt.Errorf("commit built image: %w", err)
	}
	for _, target := range targets[1:] {
		if _, err := b.TagImage(ctx, api.ImageTagRequest{Source: image.Name, Target: target}); err != nil {
			return api.ImageResponse{}, fmt.Errorf("tag built image %q: %w", target, err)
		}
	}
	return image, nil
}

func applyBuildStageChange(
	ctx context.Context, b *Backend, id string, state *buildStageState, raw string,
) error {
	parts := strings.SplitN(strings.TrimSpace(raw), " ", 2)
	if len(parts) != 2 {
		return errors.New("Dockerfile change requires a value")
	}
	instruction := strings.ToUpper(parts[0])
	argument := strings.TrimSpace(parts[1])
	switch instruction {
	case "ENV":
		return applyBuildEnvironment(&state.env, argument)
	case "USER":
		if argument == "" {
			return errors.New("USER requires a value")
		}
		argument = substituteBuildVariables(argument, buildEnvironmentVariables(state.env))
		state.user = argument
		return nil
	case "WORKDIR":
		if argument == "" {
			return errors.New("WORKDIR requires a value")
		}
		argument = substituteBuildVariables(argument, buildEnvironmentVariables(state.env))
		state.cwd = resolveBuildPath(state.cwd, argument)
		return ensureBuildDirectory(ctx, b, id, state.cwd)
	case "SHELL":
		var shell []string
		if err := json.Unmarshal([]byte(argument), &shell); err != nil || len(shell) == 0 {
			return errors.New("SHELL requires a non-empty JSON array")
		}
		state.shell = shell
		return nil
	default:
		// CMD, ENTRYPOINT, LABEL, EXPOSE, VOLUME, STOPSIGNAL, and HEALTHCHECK
		// affect the image configuration at commit time, but not the process
		// that executes a preceding or following RUN instruction.
		return nil
	}
}

func buildEnvironmentVariables(environment []string) map[string]string {
	variables := make(map[string]string, len(environment))
	for _, value := range environment {
		key, replacement, ok := strings.Cut(value, "=")
		if ok && key != "" {
			variables[key] = replacement
		}
	}
	return variables
}

func applyBuildEnvironment(environment *[]string, argument string) error {
	assignments, err := commitAssignments(argument, "ENV")
	if err != nil {
		return err
	}
	variables := buildEnvironmentVariables(*environment)
	for _, assignment := range assignments {
		key, value, _ := strings.Cut(assignment, "=")
		value = substituteBuildVariables(value, variables)
		assignment = key + "=" + value
		if err := applyCommitEnvironment(environment, assignment); err != nil {
			return err
		}
		variables[key] = value
	}
	return nil
}

func applyBuildCopy(
	ctx context.Context,
	b *Backend,
	contextData []byte,
	dockerfile string,
	id string,
	copyInstruction buildCopy,
	cwd string,
	stageIndex int,
	stageContainers []string,
	stageNames map[string]string,
	cleanupIDs *[]string,
) error {
	copyInstruction.destination = resolveBuildPath(cwd, copyInstruction.destination)
	if copyInstruction.from == "" {
		if copyInstruction.remote {
			for _, source := range copyInstruction.sources {
				archiveData, err := downloadBuildSource(ctx, source, copyInstruction.destination)
				if err != nil {
					return fmt.Errorf("download ADD source %q: %w", source, err)
				}
				if err := b.PutArchive(ctx, api.ContainerArchivePutRequest{
					ID: id, Path: "/", Data: archiveData,
				}); err != nil {
					return fmt.Errorf("apply remote ADD archive: %w", err)
				}
			}
			return nil
		}
		if copyInstruction.add {
			for _, source := range copyInstruction.sources {
				data, found, err := readBuildContextFile(contextData, source)
				if err != nil {
					return fmt.Errorf("read ADD source %q: %w", source, err)
				}
				if !found || !isBuildArchive(data) {
					continue
				}
				extracted, err := rewriteArchiveContents(data, copyInstruction.destination)
				if err != nil {
					return fmt.Errorf("extract ADD source %q: %w", source, err)
				}
				if err := b.PutArchive(ctx, api.ContainerArchivePutRequest{
					ID: id, Path: "/", Data: extracted,
				}); err != nil {
					return fmt.Errorf("apply ADD archive: %w", err)
				}
			}
			// Non-archive ADD uses the same context path rules as COPY.
		}
		contextArchive, err := filterBuildContext(
			contextData, dockerfile, []buildCopy{copyInstruction},
		)
		if err != nil {
			return err
		}
		if len(contextArchive) == 0 {
			return nil
		}
		if err := b.PutArchive(ctx, api.ContainerArchivePutRequest{
			ID: id, Path: "/", Data: contextArchive,
		}); err != nil {
			return fmt.Errorf("apply build context archive: %w", err)
		}
		return nil
	}

	sourceID, err := resolveBuildStage(
		ctx, b, copyInstruction.from, stageIndex, stageContainers, stageNames, cleanupIDs,
	)
	if err != nil {
		return fmt.Errorf("resolve source stage %q: %w", copyInstruction.from, err)
	}
	for _, source := range copyInstruction.sources {
		archiveData, err := archiveBuildPath(ctx, b, sourceID, source)
		if err != nil {
			return fmt.Errorf("archive source %q: %w", source, err)
		}
		rewritten, err := rewriteBuildArchive(
			archiveData, source, copyInstruction.destination, len(copyInstruction.sources) > 1,
		)
		if err != nil {
			return fmt.Errorf("rewrite source archive: %w", err)
		}
		if err := b.PutArchive(ctx, api.ContainerArchivePutRequest{
			ID: id, Path: "/", Data: rewritten,
		}); err != nil {
			return fmt.Errorf("apply source archive: %w", err)
		}
	}
	return nil
}

func ensureBuildDirectory(ctx context.Context, b *Backend, id, directory string) error {
	directory = path.Clean(directory)
	if directory == "." || directory == "/" || directory == "" {
		return nil
	}
	name := strings.TrimPrefix(cleanBuildPath(directory), "/") + "/"
	var archive bytes.Buffer
	writer := tar.NewWriter(&archive)
	if err := writer.WriteHeader(&tar.Header{Name: name, Mode: 0o755, Typeflag: tar.TypeDir}); err != nil {
		return err
	}
	if err := writer.Close(); err != nil {
		return err
	}
	return b.PutArchive(ctx, api.ContainerArchivePutRequest{ID: id, Path: "/", Data: archive.Bytes()})
}

func resolveBuildPath(cwd, value string) string {
	value = strings.TrimSpace(value)
	if strings.HasPrefix(value, "/") {
		return path.Clean(value)
	}
	if cwd == "" {
		cwd = "/"
	}
	return path.Clean(path.Join(cwd, value))
}

func readBuildFile(contextData []byte, name string) ([]byte, error) {
	reader, closeReader, err := buildTarReader(contextData)
	if err != nil {
		return nil, err
	}
	defer closeReader()
	expected := cleanBuildPath(name)
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("read build context: %w", err)
		}
		if cleanBuildPath(header.Name) != expected {
			continue
		}
		if header.Size < 0 || header.Size > maxDockerfileBytes {
			return nil, errors.New("Dockerfile is too large")
		}
		data, err := io.ReadAll(io.LimitReader(reader, maxDockerfileBytes+1))
		if err != nil {
			return nil, fmt.Errorf("read Dockerfile: %w", err)
		}
		if int64(len(data)) > maxDockerfileBytes {
			return nil, errors.New("Dockerfile is too large")
		}
		return data, nil
	}
	return nil, fmt.Errorf("Dockerfile %q is missing from the build context", name)
}

func parseBuildDockerfile(data []byte) (buildPlan, error) {
	return parseBuildDockerfileWithArgs(data, nil)
}

func parseBuildDockerfileWithArgs(data []byte, buildArgs map[string]string) (buildPlan, error) {
	var plan buildPlan
	var current *buildStage
	variables := make(map[string]string, len(buildArgs))
	for key, value := range buildArgs {
		variables[key] = value
	}
	scanner := bufio.NewScanner(bytes.NewReader(data))
	scanner.Buffer(make([]byte, 1024), maxDockerfileBytes)
	var pending string
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasSuffix(line, "\\") {
			pending += strings.TrimSpace(strings.TrimSuffix(line, "\\")) + " "
			continue
		}
		line = strings.TrimSpace(pending + line)
		pending = ""
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = substituteBuildVariables(line, variables)
		parts := strings.SplitN(line, " ", 2)
		instruction := strings.ToUpper(parts[0])
		argument := ""
		if len(parts) == 2 {
			argument = strings.TrimSpace(parts[1])
		}
		switch instruction {
		case "FROM":
			fields := strings.Fields(argument)
			if len(fields) == 0 {
				return buildPlan{}, errors.New("FROM requires an image")
			}
			if strings.HasPrefix(fields[0], "--platform=") {
				fields = fields[1:]
			}
			if len(fields) == 0 {
				return buildPlan{}, errors.New("FROM requires an image")
			}
			stage := buildStage{base: fields[0], shell: []string{"/bin/sh", "-c"}}
			for index := 1; index+1 < len(fields); index++ {
				if strings.EqualFold(fields[index], "as") {
					stage.name = fields[index+1]
					break
				}
			}
			plan.stages = append(plan.stages, stage)
			current = &plan.stages[len(plan.stages)-1]
			if plan.base == "" {
				plan.base = stage.base
			}
		case "RUN":
			if current == nil {
				return buildPlan{}, errors.New("Dockerfile instruction appears before FROM")
			}
			if argument == "" {
				return buildPlan{}, errors.New("RUN requires a command")
			}
			run := buildRun{command: argument, shell: true}
			if strings.HasPrefix(strings.TrimSpace(argument), "[") {
				if err := json.Unmarshal([]byte(argument), &run.args); err != nil || len(run.args) == 0 {
					return buildPlan{}, errors.New("RUN exec form requires a non-empty JSON string array")
				}
				run.shell = false
			}
			current.runs = append(current.runs, argument)
			current.instructions = append(current.instructions, buildInstruction{kind: "run", run: run})
			if len(plan.stages) == 1 {
				plan.runs = append(plan.runs, argument)
			}
		case "CMD", "ENTRYPOINT", "ENV", "LABEL", "EXPOSE", "VOLUME", "USER", "WORKDIR", "STOPSIGNAL", "HEALTHCHECK":
			if current == nil {
				return buildPlan{}, errors.New("Dockerfile instruction appears before FROM")
			}
			if argument == "" {
				return buildPlan{}, fmt.Errorf("%s requires a value", instruction)
			}
			if instruction == "ENV" {
				assignments, err := commitAssignments(argument, "ENV")
				if err != nil {
					return buildPlan{}, err
				}
				for _, assignment := range assignments {
					key, value, _ := strings.Cut(assignment, "=")
					variables[key] = value
				}
			}
			current.changes = append(current.changes, instruction+" "+argument)
			current.instructions = append(current.instructions, buildInstruction{
				kind: "change", change: instruction + " " + argument,
			})
			if len(plan.stages) == 1 {
				plan.changes = append(plan.changes, instruction+" "+argument)
			}
		case "COPY", "ADD":
			copyInstruction, err := parseBuildCopy(argument, instruction == "ADD")
			if err != nil {
				return buildPlan{}, fmt.Errorf("%s: %w", instruction, err)
			}
			if current == nil {
				return buildPlan{}, errors.New("Dockerfile instruction appears before FROM")
			}
			current.copies = append(current.copies, copyInstruction)
			current.instructions = append(current.instructions, buildInstruction{
				kind: "copy", copy: copyInstruction,
			})
			if len(plan.stages) == 1 {
				plan.copies = append(plan.copies, copyInstruction)
			}
		case "ARG":
			fields := strings.SplitN(argument, "=", 2)
			name := strings.TrimSpace(fields[0])
			if name == "" || strings.ContainsAny(name, " \t") {
				return buildPlan{}, errors.New("ARG requires a valid name")
			}
			if _, supplied := variables[name]; !supplied {
				if len(fields) == 2 {
					variables[name] = fields[1]
				} else {
					variables[name] = ""
				}
			}
		case "SHELL":
			if current == nil {
				return buildPlan{}, errors.New("Dockerfile instruction appears before FROM")
			}
			var shell []string
			if err := json.Unmarshal([]byte(argument), &shell); err != nil || len(shell) == 0 {
				return buildPlan{}, errors.New("SHELL requires a non-empty JSON array")
			}
			current.shell = shell
			current.changes = append(current.changes, instruction+" "+argument)
			if len(plan.stages) == 1 {
				plan.changes = append(plan.changes, instruction+" "+argument)
			}
		default:
			return buildPlan{}, fmt.Errorf("Dockerfile instruction %q is not supported", instruction)
		}
	}
	if err := scanner.Err(); err != nil {
		return buildPlan{}, fmt.Errorf("read Dockerfile: %w", err)
	}
	if pending != "" {
		return buildPlan{}, errors.New("Dockerfile ends with a continuation line")
	}
	return plan, nil
}

func parseBuildCopy(argument string, allowRemote bool) (buildCopy, error) {
	var fields []string
	if strings.HasPrefix(strings.TrimSpace(argument), "[") {
		if err := json.Unmarshal([]byte(argument), &fields); err != nil {
			return buildCopy{}, fmt.Errorf("invalid JSON form: %w", err)
		}
	} else {
		fields = strings.Fields(argument)
	}
	if len(fields) < 2 {
		return buildCopy{}, errors.New("requires at least one source and a destination")
	}
	remote := false
	for _, source := range fields[:len(fields)-1] {
		if strings.Contains(source, "://") {
			parsed, err := url.Parse(source)
			if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
				return buildCopy{}, fmt.Errorf("source %q is not a valid remote URL", source)
			}
			if !allowRemote {
				return buildCopy{}, fmt.Errorf("source %q is not supported by COPY", source)
			}
			remote = true
		}
	}
	from := ""
	filtered := make([]string, 0, len(fields))
	for _, field := range fields[:len(fields)-1] {
		if strings.HasPrefix(field, "--from=") {
			from = strings.TrimPrefix(field, "--from=")
			if from == "" {
				return buildCopy{}, errors.New("--from requires a stage name or index")
			}
			continue
		}
		if strings.HasPrefix(field, "--") {
			continue
		}
		filtered = append(filtered, field)
	}
	if len(filtered) == 0 {
		return buildCopy{}, errors.New("requires at least one source")
	}
	if remote && len(filtered) != 1 {
		return buildCopy{}, errors.New("remote ADD accepts exactly one source")
	}
	return buildCopy{
		sources:     filtered,
		destination: fields[len(fields)-1],
		from:        from,
		remote:      remote,
		add:         allowRemote,
	}, nil
}

func substituteBuildVariables(value string, variables map[string]string) string {
	var output strings.Builder
	output.Grow(len(value))
	for index := 0; index < len(value); {
		if value[index] != '$' {
			output.WriteByte(value[index])
			index++
			continue
		}
		if index+1 < len(value) && value[index+1] == '$' {
			output.WriteByte('$')
			index += 2
			continue
		}
		start := index + 1
		end := start
		braced := false
		if start < len(value) && value[start] == '{' {
			braced = true
			start++
			end = start
			for end < len(value) && value[end] != '}' {
				end++
			}
			if end >= len(value) {
				output.WriteByte('$')
				index++
				continue
			}
		} else {
			for end < len(value) {
				character := value[end]
				if !(character == '_' || character >= '0' && character <= '9' ||
					character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z') {
					break
				}
				end++
			}
		}
		if end == start {
			output.WriteByte('$')
			index++
			continue
		}
		name := value[start:end]
		replacement, found := variables[name]
		if !found {
			output.WriteString(value[index:end])
			if braced {
				output.WriteByte('}')
			}
			index = end
			if braced {
				index++
			}
			continue
		}
		output.WriteString(replacement)
		index = end
		if braced {
			index++
		}
	}
	return output.String()
}

func downloadBuildSource(ctx context.Context, source, destination string) ([]byte, error) {
	parsed, err := url.Parse(source)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
		return nil, fmt.Errorf("invalid remote URL %q", source)
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, parsed.String(), nil)
	if err != nil {
		return nil, err
	}
	response, err := (&http.Client{}).Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return nil, fmt.Errorf("remote source returned HTTP %s", response.Status)
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, maxBuildContextBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > maxBuildContextBytes {
		return nil, fmt.Errorf("remote source exceeds %d bytes", maxBuildContextBytes)
	}
	if isBuildArchive(data) {
		return rewriteArchiveContents(data, destination)
	}
	name := strings.TrimPrefix(cleanBuildPath(destination), "/")
	if strings.HasSuffix(destination, "/") || name == "" {
		base := path.Base(parsed.Path)
		if base == "." || base == "/" || base == "" {
			base = "download"
		}
		name = path.Join(name, base)
	}
	var archive bytes.Buffer
	writer := tar.NewWriter(&archive)
	header := &tar.Header{Name: name, Mode: 0o644, Size: int64(len(data)), ModTime: time.Unix(0, 0)}
	if err := writer.WriteHeader(header); err != nil {
		return nil, err
	}
	if _, err := writer.Write(data); err != nil {
		return nil, err
	}
	if err := writer.Close(); err != nil {
		return nil, err
	}
	return archive.Bytes(), nil
}

func filterBuildContext(contextData []byte, dockerfile string, copies []buildCopy) ([]byte, error) {
	reader, closeReader, err := buildTarReader(contextData)
	if err != nil {
		return nil, err
	}
	defer closeReader()
	ignorePatterns, err := readBuildIgnorePatterns(contextData)
	if err != nil {
		return nil, err
	}
	var output bytes.Buffer
	writer := tar.NewWriter(&output)
	defer writer.Close()
	matchedSources := make([][]bool, len(copies))
	for index, copyInstruction := range copies {
		if copyInstruction.from != "" || copyInstruction.remote {
			continue
		}
		matchedSources[index] = make([]bool, len(copyInstruction.sources))
	}
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("read build context: %w", err)
		}
		entryName := cleanBuildPath(header.Name)
		var entryData []byte
		if header.Size > 0 {
			if header.Size > maxBuildContextBytes {
				return nil, fmt.Errorf("build context entry %q is too large", header.Name)
			}
			entryData, err = io.ReadAll(io.LimitReader(reader, header.Size+1))
			if err != nil {
				return nil, fmt.Errorf("read build context entry %q: %w", header.Name, err)
			}
			if int64(len(entryData)) != header.Size {
				return nil, fmt.Errorf("build context entry %q is truncated", header.Name)
			}
		}
		for copyIndex, copyInstruction := range copies {
			if copyInstruction.from != "" || copyInstruction.remote {
				continue
			}
			for sourceIndex, source := range copyInstruction.sources {
				if buildSourceMatches(entryName, source) {
					matchedSources[copyIndex][sourceIndex] = true
				}
			}
		}
		if entryName == cleanBuildPath(dockerfile) || entryName == ".dockerignore" {
			continue
		}
		if matchesDockerIgnore(entryName, ignorePatterns) {
			continue
		}
		skipArchive := false
		for _, copyInstruction := range copies {
			if copyInstruction.from != "" || copyInstruction.remote || !copyInstruction.add || header.Typeflag != tar.TypeReg {
				continue
			}
			for _, source := range copyInstruction.sources {
				if !strings.ContainsAny(cleanBuildPath(source), "*?[") &&
					buildSourceMatches(entryName, source) && isBuildArchive(entryData) {
					skipArchive = true
				}
			}
		}
		if skipArchive {
			continue
		}
		for _, copyInstruction := range copies {
			if copyInstruction.from != "" || copyInstruction.remote {
				continue
			}
			for _, source := range copyInstruction.sources {
				sourceName := cleanBuildPath(source)
				if !buildSourceMatches(entryName, source) {
					continue
				}
				targetSourceName := sourceName
				if strings.ContainsAny(sourceName, "*?[") {
					targetSourceName = entryName
				}
				targetName := copyTargetName(entryName, targetSourceName, copyInstruction.destination, len(copyInstruction.sources) > 1, header)
				copyHeader := *header
				copyHeader.Name = targetName
				if err := writer.WriteHeader(&copyHeader); err != nil {
					return nil, fmt.Errorf("write build context: %w", err)
				}
				if len(entryData) > 0 {
					if _, err := writer.Write(entryData); err != nil {
						return nil, fmt.Errorf("copy build context: %w", err)
					}
				}
				break
			}
		}
	}
	for copyIndex, copyInstruction := range copies {
		if copyInstruction.from != "" || copyInstruction.remote {
			continue
		}
		for sourceIndex, matched := range matchedSources[copyIndex] {
			if !matched {
				return nil, fmt.Errorf("build source %q was not found in the context", copyInstruction.sources[sourceIndex])
			}
		}
	}
	if err := writer.Close(); err != nil {
		return nil, fmt.Errorf("close build context: %w", err)
	}
	return output.Bytes(), nil
}

func readBuildIgnorePatterns(contextData []byte) ([]string, error) {
	reader, closeReader, err := buildTarReader(contextData)
	if err != nil {
		return nil, err
	}
	defer closeReader()
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			return nil, nil
		}
		if err != nil {
			return nil, fmt.Errorf("read .dockerignore: %w", err)
		}
		if cleanBuildPath(header.Name) != ".dockerignore" {
			continue
		}
		data, err := io.ReadAll(io.LimitReader(reader, maxDockerfileBytes+1))
		if err != nil {
			return nil, fmt.Errorf("read .dockerignore: %w", err)
		}
		if int64(len(data)) > maxDockerfileBytes {
			return nil, errors.New(".dockerignore is too large")
		}
		lines := strings.Split(string(data), "\n")
		patterns := make([]string, 0, len(lines))
		for _, line := range lines {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			patterns = append(patterns, line)
		}
		return patterns, nil
	}
}

func matchesDockerIgnore(name string, patterns []string) bool {
	ignored := false
	for _, pattern := range patterns {
		negated := strings.HasPrefix(pattern, "!")
		if negated {
			pattern = strings.TrimPrefix(pattern, "!")
		}
		pattern = strings.Trim(pattern, "/")
		if pattern == "" || pattern == "." {
			continue
		}
		matched := buildSourceMatches(name, pattern)
		if !matched && !strings.Contains(pattern, "/") {
			matched = buildSourceMatches(path.Base(name), pattern)
		}
		if matched {
			ignored = !negated
		}
	}
	return ignored
}

func resolveBuildStage(
	ctx context.Context,
	b *Backend,
	from string,
	stageIndex int,
	stageContainers []string,
	stageNames map[string]string,
	cleanupIDs *[]string,
) (string, error) {
	if id := stageNames[strings.ToLower(from)]; id != "" {
		return id, nil
	}
	if index, err := strconv.Atoi(from); err == nil && index >= 0 && index < stageIndex {
		return stageContainers[index], nil
	}
	image, err := b.Pull(ctx, api.ImagePullRequest{Reference: from, Snapshotter: "overlayfs"})
	if err != nil {
		return "", fmt.Errorf("pull external stage %q: %w", from, err)
	}
	id := fmt.Sprintf("glassdock-build-external-%d", time.Now().UnixNano())
	keepAlive := []string{"/bin/sh", "-c", "while :; do sleep 3600; done"}
	if _, err := b.Create(ctx, api.ContainerCreateRequest{ID: id, Image: image.Name, Cmd: &keepAlive}); err != nil {
		return "", err
	}
	// The caller's cleanup list is intentionally a slice value. External stages
	// are short-lived and are removed immediately after their archive is used by
	// the caller's deferred cleanup through the same container lifecycle.
	*cleanupIDs = append(*cleanupIDs, id)
	return id, nil
}

func archiveBuildPath(ctx context.Context, b *Backend, id, source string) ([]byte, error) {
	var data bytes.Buffer
	err := b.ArchiveContainer(ctx, api.ContainerArchiveRequest{ID: id, Path: source}, func(_ string, chunk []byte) error {
		_, err := data.Write(chunk)
		return err
	})
	return data.Bytes(), err
}

func readBuildContextFile(contextData []byte, source string) ([]byte, bool, error) {
	reader, closeReader, err := buildTarReader(contextData)
	if err != nil {
		return nil, false, err
	}
	defer closeReader()
	wanted := cleanBuildPath(source)
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			return nil, false, nil
		}
		if err != nil {
			return nil, false, err
		}
		if cleanBuildPath(header.Name) != wanted || header.Typeflag != tar.TypeReg {
			continue
		}
		if header.Size < 0 || header.Size > maxBuildContextBytes {
			return nil, false, fmt.Errorf("build context entry %q is too large", source)
		}
		data, err := io.ReadAll(io.LimitReader(reader, header.Size+1))
		if err != nil {
			return nil, false, err
		}
		if int64(len(data)) != header.Size {
			return nil, false, fmt.Errorf("build context entry %q is truncated", source)
		}
		return data, true, nil
	}
}

func isBuildArchive(data []byte) bool {
	if len(data) == 0 {
		return false
	}
	reader, closeReader, err := buildTarReader(data)
	if err != nil {
		return false
	}
	defer closeReader()
	_, err = reader.Next()
	return err == nil
}

func rewriteArchiveContents(data []byte, destination string) ([]byte, error) {
	reader, closeReader, err := buildTarReader(data)
	if err != nil {
		return nil, err
	}
	defer closeReader()
	var output bytes.Buffer
	writer := tar.NewWriter(&output)
	destinationName := strings.TrimPrefix(cleanBuildPath(destination), "/")
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		name := cleanBuildPath(header.Name)
		if name == "" || strings.HasPrefix(name, "../") || name == ".." {
			return nil, fmt.Errorf("archive entry %q escapes the build root", header.Name)
		}
		target := name
		if destinationName != "" {
			target = path.Join(destinationName, name)
		}
		copyHeader := *header
		copyHeader.Name = target
		if err := writer.WriteHeader(&copyHeader); err != nil {
			return nil, err
		}
		if header.Size > 0 {
			if _, err := io.CopyN(writer, reader, header.Size); err != nil {
				return nil, err
			}
		}
	}
	if err := writer.Close(); err != nil {
		return nil, err
	}
	return output.Bytes(), nil
}

func rewriteBuildArchive(data []byte, source, destination string, multipleSources bool) ([]byte, error) {
	reader := tar.NewReader(bytes.NewReader(data))
	var output bytes.Buffer
	writer := tar.NewWriter(&output)
	sourceName := strings.TrimPrefix(strings.TrimSuffix(cleanBuildPath(source), "/"), "/")
	destinationName := strings.TrimPrefix(cleanBuildPath(destination), "/")
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		name := cleanBuildPath(header.Name)
		relative := strings.TrimPrefix(name, sourceName)
		relative = strings.TrimPrefix(relative, "/")
		target := destinationName
		if multipleSources || strings.HasSuffix(destination, "/") || relative != "" && header.Typeflag == tar.TypeDir {
			target = path.Join(destinationName, relative)
		}
		if target == "" {
			target = path.Base(sourceName)
		}
		if relative == "" && header.Typeflag == tar.TypeDir {
			// PutArchive creates the destination directory as needed.  The root
			// header would otherwise make /dest/dest for directory copies.
			continue
		}
		copyHeader := *header
		copyHeader.Name = target
		if err := writer.WriteHeader(&copyHeader); err != nil {
			return nil, err
		}
		if header.Size > 0 {
			if _, err := io.CopyN(writer, reader, header.Size); err != nil {
				return nil, err
			}
		}
	}
	if err := writer.Close(); err != nil {
		return nil, err
	}
	return output.Bytes(), nil
}

func buildSourceMatches(entryName, source string) bool {
	sourceName := strings.TrimSuffix(cleanBuildPath(source), "/")
	if sourceName == "" {
		return entryName != ""
	}
	if strings.ContainsAny(sourceName, "*?[") {
		matched, err := path.Match(sourceName, entryName)
		return err == nil && matched
	}
	return entryName == sourceName || strings.HasPrefix(entryName, sourceName+"/")
}

func copyTargetName(entryName, sourceName, destination string, multipleSources bool, header *tar.Header) string {
	destinationName := strings.TrimPrefix(cleanBuildPath(destination), "/")
	relative := strings.TrimPrefix(entryName, sourceName)
	relative = strings.TrimPrefix(relative, "/")
	copyDirectory := header.Typeflag == tar.TypeDir || relative != ""
	if multipleSources || strings.HasSuffix(destination, "/") || copyDirectory {
		return path.Join(destinationName, path.Base(sourceName), relative)
	}
	return destinationName
}

func buildTarReader(data []byte) (*tar.Reader, func(), error) {
	if len(data) >= 2 && data[0] == 0x1f && data[1] == 0x8b {
		gzipReader, err := gzip.NewReader(bytes.NewReader(data))
		if err != nil {
			return nil, func() {}, fmt.Errorf("open compressed build context: %w", err)
		}
		decompressed, err := io.ReadAll(io.LimitReader(gzipReader, maxBuildContextBytes+1))
		closeErr := gzipReader.Close()
		if err != nil {
			return nil, func() {}, fmt.Errorf("read compressed build context: %w", err)
		}
		if closeErr != nil {
			return nil, func() {}, fmt.Errorf("close compressed build context: %w", closeErr)
		}
		if len(decompressed) > maxBuildContextBytes {
			return nil, func() {}, fmt.Errorf("compressed build context exceeds %d bytes", maxBuildContextBytes)
		}
		return tar.NewReader(bytes.NewReader(decompressed)), func() {}, nil
	}
	return tar.NewReader(bytes.NewReader(data)), func() {}, nil
}

func cleanBuildPath(name string) string {
	name = strings.TrimPrefix(name, "./")
	cleaned := path.Clean(name)
	if cleaned == "." {
		return ""
	}
	return cleaned
}

func splitBuildTag(target string) (string, string) {
	target = strings.TrimSpace(target)
	if target == "" {
		return "glassdock/build", "latest"
	}
	lastSlash := strings.LastIndex(target, "/")
	lastColon := strings.LastIndex(target, ":")
	if lastColon > lastSlash && lastColon < len(target)-1 {
		return target[:lastColon], target[lastColon+1:]
	}
	return target, "latest"
}
