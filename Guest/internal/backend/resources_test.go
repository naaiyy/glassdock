package backend

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/glassdock/glassdock/guest/internal/api"
	"github.com/opencontainers/runtime-spec/specs-go"
)

func TestMapDockerResources(t *testing.T) {
	tests := []struct {
		name          string
		input         api.Resources
		wantCPU       bool
		wantMemory    bool
		wantPids      bool
		wantQuota     int64
		wantPeriod    uint64
		wantSwap      int64
		wantPidsLimit bool
	}{
		{
			name:       "nano cpus uses one hundred millisecond period",
			input:      api.Resources{NanoCPUs: 500_000_000},
			wantCPU:    true,
			wantQuota:  50_000,
			wantPeriod: 100_000,
		},
		{
			name: "all requested controllers map to OCI resources",
			input: api.Resources{
				Memory: 268_435_456, MemorySwap: 536_870_912, MemoryReservation: 134_217_728,
				CPUShares: 512, CPUPeriod: 100_000, CPUQuota: 50_000,
				CPUSetCPUs: "0-1", CPUSetMems: "0", PidsLimit: 64,
			},
			wantCPU: true, wantMemory: true, wantPids: true,
			wantQuota: 50_000, wantPeriod: 100_000, wantSwap: 536_870_912,
			wantPidsLimit: true,
		},
		{
			name:       "zero swap follows Docker two times memory default",
			input:      api.Resources{Memory: 128},
			wantMemory: true,
			wantSwap:   256,
		},
		{
			name:       "negative swap remains unlimited",
			input:      api.Resources{Memory: 128, MemorySwap: -1},
			wantMemory: true,
			wantSwap:   -1,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			resources, ok, err := mapDockerResources(test.input)
			if err != nil {
				t.Fatal(err)
			}
			if !ok {
				t.Fatal("resource request was not marked active")
			}
			if (resources.CPU != nil) != test.wantCPU {
				t.Fatalf("CPU section presence = %v, want %v", resources.CPU != nil, test.wantCPU)
			}
			if (resources.Memory != nil) != test.wantMemory {
				t.Fatalf("memory section presence = %v, want %v", resources.Memory != nil, test.wantMemory)
			}
			if (resources.Pids != nil) != test.wantPids {
				t.Fatalf("pids section presence = %v, want %v", resources.Pids != nil, test.wantPids)
			}
			if resources.CPU != nil {
				if resources.CPU.Quota == nil || *resources.CPU.Quota != test.wantQuota {
					t.Fatalf("unexpected CPU quota: %+v", resources.CPU.Quota)
				}
				if test.wantPeriod != 0 && (resources.CPU.Period == nil || *resources.CPU.Period != test.wantPeriod) {
					t.Fatalf("unexpected CPU period: %+v", resources.CPU.Period)
				}
			}
			if resources.Memory != nil {
				if resources.Memory.Swap == nil || *resources.Memory.Swap != test.wantSwap {
					t.Fatalf("unexpected memory swap: %+v", resources.Memory.Swap)
				}
			}
			if test.wantMemory {
				if resources.Memory.Limit == nil || *resources.Memory.Limit != test.input.Memory {
					t.Fatalf("unexpected memory limit: %+v", resources.Memory.Limit)
				}
				if test.input.MemoryReservation > 0 &&
					(resources.Memory.Reservation == nil || *resources.Memory.Reservation != test.input.MemoryReservation) {
					t.Fatalf("unexpected memory reservation: %+v", resources.Memory.Reservation)
				}
			}
			if test.wantPidsLimit && resources.Pids.Limit != test.input.PidsLimit {
				t.Fatalf("unexpected pids limit: %d", resources.Pids.Limit)
			}
		})
	}
}

func TestMergeDockerResourceUpdateClearsMemoryState(t *testing.T) {
	memory := int64(0)
	merged, err := mergeDockerResourceUpdate(api.Resources{
		Memory: 128, MemorySwap: 256, MemoryReservation: 64,
	}, api.ContainerUpdateRequest{Memory: &memory})
	if err != nil {
		t.Fatal(err)
	}
	if merged.Memory != 0 || merged.MemorySwap != 0 || merged.MemoryReservation != 0 {
		t.Fatalf("cleared memory state = %+v", merged)
	}
}

func TestWrapResourceApplicationErrorPreservesTypedErrors(t *testing.T) {
	original := resourceLimitError("controller unavailable")
	if got := wrapResourceApplicationError(original); got != original {
		t.Fatal("typed resource errors should not be wrapped twice")
	}
	if !strings.Contains(wrapResourceApplicationError(os.ErrPermission).Error(), "could not be applied") {
		t.Fatal("runtime application errors should identify resource application")
	}
}

func TestMapDockerResourcesRejectsInvalidMemorySwap(t *testing.T) {
	_, _, err := mapDockerResources(api.Resources{Memory: 100, MemorySwap: 99})
	if err == nil || !strings.Contains(err.Error(), "MemorySwap") {
		t.Fatalf("mapDockerResources error = %v, want MemorySwap validation error", err)
	}
}

func TestEnsureCgroupControllers(t *testing.T) {
	root := t.TempDir()
	writeCgroupFixture(t, root, "cpu cpuset memory pids", "cpu cpuset memory pids")

	if err := ensureCgroupControllers(root, linuxResourcesForTest()); err != nil {
		t.Fatal(err)
	}

	t.Run("rejects unavailable controller", func(t *testing.T) {
		missing := t.TempDir()
		writeCgroupFixture(t, missing, "cpu memory pids", "cpu memory pids")
		err := ensureCgroupControllers(missing, linuxResourcesForTest())
		if err == nil || !strings.Contains(err.Error(), "cpuset") {
			t.Fatalf("ensureCgroupControllers error = %v, want cpuset error", err)
		}
	})

	t.Run("rejects missing cgroup v2 hierarchy", func(t *testing.T) {
		err := ensureCgroupControllers(t.TempDir(), linuxResourcesForTest())
		if err == nil || !strings.Contains(err.Error(), "cgroup v2") {
			t.Fatalf("ensureCgroupControllers error = %v, want hierarchy error", err)
		}
	})
}

func linuxResourcesForTest() *specs.LinuxResources {
	return &specs.LinuxResources{
		CPU:    &specs.LinuxCPU{Quota: resourceInt64Pointer(1), Cpus: "0"},
		Memory: &specs.LinuxMemory{Limit: resourceInt64Pointer(1)},
		Pids:   &specs.LinuxPids{Limit: 1},
	}
}

func resourceInt64Pointer(value int64) *int64 { return &value }

func writeCgroupFixture(t *testing.T, root, controllers, enabled string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(root, "cgroup.controllers"), []byte(controllers), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "cgroup.subtree_control"), []byte(enabled), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestDockerSocketRelayMountRequiresInternalMarker(t *testing.T) {
	tests := []struct {
		name  string
		mount api.Mount
		valid bool
	}{
		{
			name:  "daemon marker",
			mount: api.Mount{Source: api.DockerSocketRelayPath, Type: "bind", Relay: true},
			valid: true,
		},
		{
			name:  "missing marker",
			mount: api.Mount{Source: api.DockerSocketRelayPath, Type: "bind"},
		},
		{
			name:  "wrong source",
			mount: api.Mount{Source: "/run/other.sock", Type: "bind", Relay: true},
		},
		{
			name:  "wrong type",
			mount: api.Mount{Source: api.DockerSocketRelayPath, Type: "tmpfs", Relay: true},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := isDockerSocketRelayMount(test.mount); got != test.valid {
				t.Fatalf("isDockerSocketRelayMount() = %v, want %v", got, test.valid)
			}
		})
	}
}
