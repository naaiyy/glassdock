package backend

import (
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/glassdock/glassdock/guest/internal/api"
	"github.com/opencontainers/runtime-spec/specs-go"
)

const (
	defaultCgroupRoot = "/sys/fs/cgroup"
	defaultCPUPeriod  = uint64(100_000)
)

// ResourceLimitError marks failures that Docker reports as an invalid
// request. The guest protocol uses this type to keep cgroup setup failures
// from being returned as opaque containerd failures.
type ResourceLimitError struct {
	err error
}

func (e *ResourceLimitError) Error() string { return e.err.Error() }

func (e *ResourceLimitError) Unwrap() error { return e.err }

func resourceLimitError(format string, args ...any) error {
	return &ResourceLimitError{err: fmt.Errorf(format, args...)}
}

func wrapResourceApplicationError(err error) error {
	if err == nil {
		return nil
	}
	var resourceError *ResourceLimitError
	if errors.As(err, &resourceError) {
		return err
	}
	return resourceLimitError("resource limits could not be applied: %w", err)
}

type resourceMapping struct {
	name    string
	enabled func(api.Resources) bool
	apply   func(api.Resources, *specs.LinuxResources)
}

// Keep the Docker-to-OCI mapping in one table. This makes the fields that
// activate each OCI resource controller explicit and keeps create and update
// paths on the same mapping implementation.
var resourceMappings = []resourceMapping{
	{
		name: "cpu",
		enabled: func(resources api.Resources) bool {
			return resources.NanoCPUs != 0 || resources.CPUShares != 0 ||
				resources.CPUPeriod != 0 || resources.CPUQuota != 0 ||
				resources.CPUSetCPUs != "" || resources.CPUSetMems != ""
		},
		apply: applyCPUResources,
	},
	{
		name: "memory",
		enabled: func(resources api.Resources) bool {
			return resources.Memory != 0 || resources.MemorySwap != 0 || resources.MemoryReservation != 0
		},
		apply: applyMemoryResources,
	},
	{
		name: "pids",
		enabled: func(resources api.Resources) bool {
			return resources.PidsLimit != 0
		},
		apply: applyPidsResources,
	},
}

func mapDockerResources(request api.Resources) (*specs.LinuxResources, bool, error) {
	normalized, err := normalizeDockerResources(request)
	if err != nil {
		return nil, false, err
	}
	return mapNormalizedResources(normalized)
}

func mapNormalizedResources(request api.Resources) (*specs.LinuxResources, bool, error) {
	resources := &specs.LinuxResources{}
	hasResources := false
	for _, mapping := range resourceMappings {
		if !mapping.enabled(request) {
			continue
		}
		mapping.apply(request, resources)
		hasResources = true
	}
	if !hasResources {
		return nil, false, nil
	}
	return resources, true, nil
}

func normalizeDockerResources(resources api.Resources) (api.Resources, error) {
	if resources.Memory < 0 {
		return api.Resources{}, resourceLimitError("Memory must be non-negative")
	}
	if resources.MemorySwap < -1 {
		return api.Resources{}, resourceLimitError("MemorySwap must be -1 or non-negative")
	}
	if resources.MemoryReservation < 0 {
		return api.Resources{}, resourceLimitError("MemoryReservation must be non-negative")
	}
	if resources.NanoCPUs < 0 {
		return api.Resources{}, resourceLimitError("NanoCpus must be non-negative")
	}
	if resources.CPUShares < 0 || resources.CPUShares > 0 && resources.CPUShares < 2 {
		return api.Resources{}, resourceLimitError("CpuShares must be 0 or between 2 and 262144")
	}
	if resources.CPUShares > 262_144 {
		return api.Resources{}, resourceLimitError("CpuShares must be 0 or between 2 and 262144")
	}
	if resources.CPUPeriod < 0 {
		return api.Resources{}, resourceLimitError("CpuPeriod must be non-negative")
	}
	if resources.CPUPeriod != 0 && (resources.CPUPeriod < 1_000 || resources.CPUPeriod > 1_000_000) {
		return api.Resources{}, resourceLimitError("CpuPeriod must be between 1000 and 1000000")
	}
	if resources.CPUQuota < -1 {
		return api.Resources{}, resourceLimitError("CpuQuota must be -1 or non-negative")
	}
	if resources.PidsLimit < -1 {
		return api.Resources{}, resourceLimitError("PidsLimit must be -1 or non-negative")
	}
	if resources.MemorySwap != 0 && resources.Memory == 0 {
		return api.Resources{}, resourceLimitError("MemorySwap requires Memory")
	}
	if resources.MemorySwap > 0 && resources.MemorySwap < resources.Memory {
		return api.Resources{}, resourceLimitError("MemorySwap must be greater than or equal to Memory")
	}
	if resources.MemoryReservation > resources.Memory {
		return api.Resources{}, resourceLimitError(
			"MemoryReservation must be less than or equal to Memory",
		)
	}
	if resources.NanoCPUs != 0 && (resources.CPUPeriod != 0 || resources.CPUQuota != 0) {
		return api.Resources{}, resourceLimitError("NanoCpus cannot be combined with CpuPeriod or CpuQuota")
	}
	if resources.Memory > 0 && resources.MemorySwap == 0 {
		if resources.Memory > math.MaxInt64/2 {
			return api.Resources{}, resourceLimitError("Memory is too large to calculate the default MemorySwap")
		}
		resources.MemorySwap = resources.Memory * 2
	}
	return resources, nil
}

func applyCPUResources(request api.Resources, resources *specs.LinuxResources) {
	cpu := &specs.LinuxCPU{}
	if request.NanoCPUs != 0 {
		period := defaultCPUPeriod
		cpu.Period = &period
		quota := nanoCPUQuota(request.NanoCPUs, period)
		cpu.Quota = &quota
	}
	if request.CPUShares != 0 {
		shares := uint64(request.CPUShares)
		cpu.Shares = &shares
	}
	if request.CPUPeriod != 0 {
		period := uint64(request.CPUPeriod)
		cpu.Period = &period
	}
	if request.CPUQuota != 0 {
		quota := request.CPUQuota
		cpu.Quota = &quota
	}
	cpu.Cpus = request.CPUSetCPUs
	cpu.Mems = request.CPUSetMems
	resources.CPU = cpu
}

func applyMemoryResources(request api.Resources, resources *specs.LinuxResources) {
	memory := &specs.LinuxMemory{}
	if request.Memory != 0 {
		limit := request.Memory
		memory.Limit = &limit
	}
	if request.MemorySwap != 0 {
		swap := request.MemorySwap
		memory.Swap = &swap
	}
	if request.MemoryReservation != 0 {
		reservation := request.MemoryReservation
		memory.Reservation = &reservation
	}
	resources.Memory = memory
}

func applyPidsResources(request api.Resources, resources *specs.LinuxResources) {
	limit := request.PidsLimit
	resources.Pids = &specs.LinuxPids{Limit: limit}
}

func resourceUpdateRequested(request api.ContainerUpdateRequest) bool {
	return request.NanoCPUs != nil || request.CPUShares != nil || request.Memory != nil ||
		request.MemorySwap != nil || request.MemoryReservation != nil || request.CPUPeriod != nil ||
		request.CPUQuota != nil || request.CPUSetCPUs != nil || request.CPUSetMems != nil ||
		request.PidsLimit != nil
}

func mergeDockerResourceUpdate(previous api.Resources, request api.ContainerUpdateRequest) (api.Resources, error) {
	merged := previous
	if request.NanoCPUs != nil {
		merged.NanoCPUs = *request.NanoCPUs
	}
	if request.CPUShares != nil {
		merged.CPUShares = int64(*request.CPUShares)
	}
	if request.Memory != nil {
		merged.Memory = *request.Memory
		if *request.Memory == 0 {
			if request.MemorySwap == nil {
				merged.MemorySwap = 0
			}
			if request.MemoryReservation == nil {
				merged.MemoryReservation = 0
			}
		}
	}
	if request.MemorySwap != nil {
		merged.MemorySwap = *request.MemorySwap
	}
	if request.MemoryReservation != nil {
		merged.MemoryReservation = *request.MemoryReservation
	}
	if request.CPUPeriod != nil {
		merged.CPUPeriod = int64(*request.CPUPeriod)
	}
	if request.CPUQuota != nil {
		merged.CPUQuota = *request.CPUQuota
	}
	if request.CPUSetCPUs != nil {
		merged.CPUSetCPUs = *request.CPUSetCPUs
	}
	if request.CPUSetMems != nil {
		merged.CPUSetMems = *request.CPUSetMems
	}
	if request.PidsLimit != nil {
		merged.PidsLimit = *request.PidsLimit
	}
	return normalizeDockerResources(merged)
}

func mapDockerResourceUpdate(
	previous api.Resources, request api.ContainerUpdateRequest,
) (*specs.LinuxResources, bool, error) {
	merged, err := mergeDockerResourceUpdate(previous, request)
	if err != nil {
		return nil, false, err
	}
	resources, _, err := mapNormalizedResources(merged)
	if err != nil {
		return nil, false, err
	}
	if resources == nil {
		resources = &specs.LinuxResources{}
	}
	if request.NanoCPUs != nil || request.CPUShares != nil || request.CPUPeriod != nil ||
		request.CPUQuota != nil || request.CPUSetCPUs != nil || request.CPUSetMems != nil {
		if resources.CPU == nil {
			resources.CPU = &specs.LinuxCPU{}
		}
	}
	if request.Memory != nil || request.MemorySwap != nil || request.MemoryReservation != nil {
		if resources.Memory == nil {
			resources.Memory = &specs.LinuxMemory{}
		}
		if request.Memory != nil && *request.Memory == 0 {
			limit := int64(0)
			resources.Memory.Limit = &limit
		}
		if request.MemoryReservation != nil && *request.MemoryReservation == 0 {
			reservation := int64(0)
			resources.Memory.Reservation = &reservation
		}
	}
	if request.PidsLimit != nil && *request.PidsLimit == 0 {
		resources.Pids = &specs.LinuxPids{Limit: -1}
	}
	return resources, true, nil
}

func resourcesFromOCISpec(resources *specs.LinuxResources) api.Resources {
	if resources == nil {
		return api.Resources{}
	}
	result := api.Resources{}
	if resources.CPU != nil {
		if resources.CPU.Shares != nil {
			result.CPUShares = int64(*resources.CPU.Shares)
		}
		if resources.CPU.Period != nil {
			result.CPUPeriod = int64(*resources.CPU.Period)
		}
		if resources.CPU.Quota != nil {
			result.CPUQuota = *resources.CPU.Quota
		}
		result.CPUSetCPUs = resources.CPU.Cpus
		result.CPUSetMems = resources.CPU.Mems
	}
	if resources.Memory != nil {
		if resources.Memory.Limit != nil {
			result.Memory = *resources.Memory.Limit
		}
		if resources.Memory.Swap != nil {
			result.MemorySwap = *resources.Memory.Swap
		}
		if resources.Memory.Reservation != nil {
			result.MemoryReservation = *resources.Memory.Reservation
		}
	}
	if resources.Pids != nil {
		result.PidsLimit = resources.Pids.Limit
	}
	return result
}

func applyMappedResourceUpdate(
	spec *specs.Spec, request api.ContainerUpdateRequest, mapped *specs.LinuxResources,
) error {
	if spec.Linux == nil {
		return errors.New("container has no Linux resource specification")
	}
	if spec.Linux.Resources == nil {
		spec.Linux.Resources = &specs.LinuxResources{}
	}
	resources := spec.Linux.Resources
	if request.NanoCPUs != nil || request.CPUShares != nil || request.CPUPeriod != nil ||
		request.CPUQuota != nil || request.CPUSetCPUs != nil || request.CPUSetMems != nil {
		resources.CPU = mapped.CPU
	}
	if request.Memory != nil || request.MemorySwap != nil || request.MemoryReservation != nil {
		resources.Memory = mapped.Memory
	}
	if request.PidsLimit != nil {
		resources.Pids = mapped.Pids
	}
	return nil
}

func requiredCgroupControllers(resources *specs.LinuxResources) []string {
	if resources == nil {
		return nil
	}
	set := map[string]bool{}
	if resources.CPU != nil {
		if resources.CPU.Shares != nil || resources.CPU.Period != nil || resources.CPU.Quota != nil {
			set["cpu"] = true
		}
		if resources.CPU.Cpus != "" || resources.CPU.Mems != "" {
			set["cpuset"] = true
		}
	}
	if resources.Memory != nil {
		set["memory"] = true
	}
	if resources.Pids != nil {
		set["pids"] = true
	}
	controllers := make([]string, 0, len(set))
	for controller := range set {
		controllers = append(controllers, controller)
	}
	sort.Strings(controllers)
	return controllers
}

func ensureCgroupControllers(root string, resources *specs.LinuxResources) error {
	required := requiredCgroupControllers(resources)
	if len(required) == 0 {
		return nil
	}
	availableData, err := os.ReadFile(filepath.Join(root, "cgroup.controllers"))
	if err != nil {
		return resourceLimitError("resource limits require a cgroup v2 hierarchy at %s: %w", root, err)
	}
	available := fieldsSet(string(availableData))
	missing := make([]string, 0, len(required))
	for _, controller := range required {
		if !available[controller] {
			missing = append(missing, controller)
		}
	}
	if len(missing) > 0 {
		return resourceLimitError(
			"resource limits require unavailable cgroup controllers: %s", strings.Join(missing, ", "),
		)
	}

	controlPath := filepath.Join(root, "cgroup.subtree_control")
	enabledData, err := os.ReadFile(controlPath)
	if err != nil {
		return resourceLimitError("resource limits cannot read cgroup delegation at %s: %w", root, err)
	}
	enabled := fieldsSet(string(enabledData))
	toEnable := make([]string, 0, len(required))
	for _, controller := range required {
		if !enabled[controller] {
			toEnable = append(toEnable, controller)
		}
	}
	if len(toEnable) > 0 {
		file, err := os.OpenFile(controlPath, os.O_WRONLY, 0)
		if err != nil {
			return resourceLimitError(
				"resource limits cannot delegate cgroup controllers at %s: %w", root, err,
			)
		}
		_, writeErr := file.WriteString(strings.Join(plusPrefixed(toEnable), " "))
		closeErr := file.Close()
		if writeErr != nil {
			return resourceLimitError(
				"resource limits cannot delegate cgroup controllers at %s: %w", root, writeErr,
			)
		}
		if closeErr != nil {
			return resourceLimitError(
				"resource limits cannot close cgroup delegation at %s: %w", root, closeErr,
			)
		}
		enabledData, err = os.ReadFile(controlPath)
		if err != nil {
			return resourceLimitError("resource limits cannot verify cgroup delegation at %s: %w", root, err)
		}
		enabled = fieldsSet(string(enabledData))
	}
	for _, controller := range required {
		if !enabled[controller] {
			return resourceLimitError(
				"resource limits could not delegate cgroup controller %s at %s", controller, root,
			)
		}
	}
	return nil
}

func fieldsSet(value string) map[string]bool {
	result := make(map[string]bool)
	for _, field := range strings.Fields(value) {
		result[strings.TrimPrefix(field, "+")] = true
	}
	return result
}

func plusPrefixed(values []string) []string {
	result := make([]string, len(values))
	for index, value := range values {
		result[index] = "+" + value
	}
	return result
}

func (b *Backend) ensureResourceControllers(resources *specs.LinuxResources) error {
	root := b.cgroupRoot
	if root == "" {
		root = defaultCgroupRoot
	}
	if err := ensureCgroupControllers(root, resources); err != nil {
		return err
	}
	if b.namespace == "" {
		return nil
	}
	if filepath.IsAbs(b.namespace) || b.namespace == "." || b.namespace == ".." || strings.Contains(b.namespace, string(filepath.Separator)+"..") {
		return resourceLimitError("invalid containerd namespace for cgroup delegation: %q", b.namespace)
	}
	namespaceRoot := filepath.Join(root, b.namespace)
	if err := os.MkdirAll(namespaceRoot, 0o755); err != nil {
		return resourceLimitError("resource limits cannot create cgroup namespace %s: %w", namespaceRoot, err)
	}
	return ensureCgroupControllers(namespaceRoot, resources)
}
