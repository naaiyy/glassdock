package api

import "time"

const Version = "1"

const (
	MethodPing                    = "ping"
	MethodVersion                 = "version"
	MethodEngineSync              = "engine.sync"
	MethodImagePull               = "image.pull"
	MethodImageList               = "image.list"
	MethodImageInspect            = "image.inspect"
	MethodImageDelete             = "image.delete"
	MethodImagePrune              = "image.prune"
	MethodImageTag                = "image.tag"
	MethodImagePush               = "image.push"
	MethodImageExport             = "image.export"
	MethodImageCommit             = "image.commit"
	MethodImageImport             = "image.import"
	MethodContainerList           = "container.list"
	MethodContainerInspect        = "container.inspect"
	MethodContainerLogs           = "container.logs"
	MethodContainerTop            = "container.top"
	MethodContainerStats          = "container.stats"
	MethodContainerExport         = "container.export"
	MethodContainerArchive        = "container.archive"
	MethodContainerArchiveInfo    = "container.archive.info"
	MethodContainerArchivePut     = "container.archive.put"
	MethodContainerChanges        = "container.changes"
	MethodContainerCreate         = "container.create"
	MethodContainerStart          = "container.start"
	MethodContainerWait           = "container.wait"
	MethodContainerKill           = "container.kill"
	MethodContainerPause          = "container.pause"
	MethodContainerResume         = "container.resume"
	MethodContainerResize         = "container.resize"
	MethodContainerDelete         = "container.delete"
	MethodContainerExec           = "container.exec"
	MethodContainerAttach         = "container.attach"
	MethodContainerMetadataUpdate = "container.metadata.update"
	MethodExecResize              = "exec.resize"
	MethodNetworkList             = "network.list"
	EventContainerExit            = "container.exit"
)

type ImagePullRequest struct {
	Reference   string `json:"reference"`
	Snapshotter string `json:"snapshotter,omitempty"`
	Platform    string `json:"platform,omitempty"`
	Username    string `json:"username,omitempty"`
	Secret      string `json:"secret,omitempty"`
}
type ImageResponse struct {
	Name   string `json:"name"`
	Digest string `json:"digest"`
}
type ImageRequest struct {
	Reference string `json:"reference"`
}
type ImageDeleteRequest struct {
	Reference string `json:"reference"`
	Force     bool   `json:"force,omitempty"`
}
type ImagePruneRequest struct {
	All bool `json:"all,omitempty"`
}
type ImageTagRequest struct {
	Source string `json:"source"`
	Target string `json:"target"`
}
type ImagePushRequest struct {
	Source   string `json:"source"`
	Target   string `json:"target"`
	Username string `json:"username,omitempty"`
	Secret   string `json:"secret,omitempty"`
	Platform string `json:"platform,omitempty"`
}
type ImageExportRequest struct {
	References []string `json:"references"`
}
type ImageCommitRequest struct {
	Container  string `json:"container"`
	Repository string `json:"repository,omitempty"`
	Tag        string `json:"tag,omitempty"`
	Comment    string `json:"comment,omitempty"`
	Author     string `json:"author,omitempty"`
	Pause      bool   `json:"pause,omitempty"`
	Changes    string `json:"changes,omitempty"`
}
type ImageImportRequest struct {
	Data []byte `json:"data"`
}
type ImageImportResponse struct {
	Images []ImageResponse `json:"images"`
}
type Image struct {
	ID           string            `json:"id"`
	Digest       string            `json:"digest"`
	References   []string          `json:"references"`
	CreatedAt    time.Time         `json:"createdAt"`
	Size         int64             `json:"size"`
	Labels       map[string]string `json:"labels,omitempty"`
	RootFSLayers []string          `json:"rootfsLayers,omitempty"`
	History      []ImageHistory    `json:"history,omitempty"`
}
type ImageHistory struct {
	Created   time.Time `json:"created"`
	CreatedBy string    `json:"createdBy,omitempty"`
	Tags      []string  `json:"tags,omitempty"`
	Size      int64     `json:"size"`
	Comment   string    `json:"comment,omitempty"`
	Empty     bool      `json:"emptyLayer,omitempty"`
}
type ImageListResponse struct {
	Images []Image `json:"images"`
}
type ImageDeleteResponse struct {
	Deleted   []string `json:"deleted,omitempty"`
	Untagged  []string `json:"untagged,omitempty"`
	Reclaimed int64    `json:"reclaimed,omitempty"`
}

type Empty struct{}
type PingResponse struct {
	OK bool `json:"ok"`
}
type VersionResponse struct {
	Protocol   string `json:"protocol"`
	Agent      string `json:"agent"`
	Containerd string `json:"containerd"`
}
type IDRequest struct {
	ID string `json:"id"`
}
type PublishedPort struct {
	ContainerPort uint16 `json:"containerPort"`
	GuestPort     uint16 `json:"guestPort,omitempty"`
	Protocol      string `json:"protocol,omitempty"`
	HostSource    string `json:"hostSource,omitempty"`
}
type ContainerKillRequest struct {
	ID     string `json:"id"`
	Signal uint32 `json:"signal,omitempty"`
}
type ContainerResizeRequest struct {
	ID     string `json:"id"`
	Width  uint32 `json:"width"`
	Height uint32 `json:"height"`
}
type ContainerCreateRequest struct {
	ID             string            `json:"id"`
	Image          string            `json:"image"`
	Args           []string          `json:"args,omitempty"`
	Entrypoint     *[]string         `json:"entrypoint,omitempty"`
	Cmd            *[]string         `json:"cmd,omitempty"`
	Env            []string          `json:"env,omitempty"`
	Cwd            string            `json:"cwd,omitempty"`
	User           string            `json:"user,omitempty"`
	Labels         map[string]string `json:"labels,omitempty"`
	Hostname       string            `json:"hostname,omitempty"`
	ReadonlyRootfs bool              `json:"readonlyRootfs,omitempty"`
	Mounts         []Mount           `json:"mounts,omitempty"`
	Network        Network           `json:"network,omitempty"`
	PublishedPorts []PublishedPort   `json:"publishedPorts,omitempty"`
	AutoRemove     bool              `json:"autoRemove,omitempty"`
	Snapshotter    string            `json:"snapshotter,omitempty"`
	Runtime        string            `json:"runtime,omitempty"`
	RuntimeBinary  string            `json:"runtimeBinary,omitempty"`
	Metadata       ContainerMetadata `json:"metadata,omitempty"`
}

type ContainerStartRequest struct {
	ID             string          `json:"id"`
	PublishedPorts []PublishedPort `json:"publishedPorts,omitempty"`
}

type DockerPortBinding struct {
	ContainerPort uint16  `json:"containerPort"`
	Protocol      string  `json:"protocol,omitempty"`
	HostIP        string  `json:"hostIP,omitempty"`
	HostPort      *uint16 `json:"hostPort,omitempty"`
}

type ContainerMetadata struct {
	Name           string              `json:"name,omitempty"`
	Args           []string            `json:"args,omitempty"`
	Labels         map[string]string   `json:"labels,omitempty"`
	Terminal       bool                `json:"terminal,omitempty"`
	AutoRemove     bool                `json:"autoRemove,omitempty"`
	PortBindings   []DockerPortBinding `json:"portBindings,omitempty"`
	PublishedPorts []PublishedPort     `json:"publishedPorts,omitempty"`
	LifecycleState string              `json:"lifecycleState,omitempty"`
	LastExitCode   *uint32             `json:"lastExitCode,omitempty"`
}
type ContainerMetadataUpdateRequest struct {
	ID           string              `json:"id"`
	Name         string              `json:"name,omitempty"`
	PortBindings []DockerPortBinding `json:"portBindings,omitempty"`
}

// Mount maps directly to an OCI mount. Supported types are bind, tmpfs,
// proc, sysfs, devpts, and mqueue. A bind mount requires an absolute source.
type Mount struct {
	Source   string   `json:"source,omitempty"`
	Target   string   `json:"target"`
	Type     string   `json:"type"`
	Readonly bool     `json:"readonly,omitempty"`
	Options  []string `json:"options,omitempty"`
}

// Network selects the network namespace. Mode is host, private, or path.
// The path field is required only for path mode.
type Network struct {
	Mode string `json:"mode,omitempty"`
	Path string `json:"path,omitempty"`
}
type NetworkIPAMConfig struct {
	Subnet             string            `json:"subnet,omitempty"`
	IPRange            string            `json:"ipRange,omitempty"`
	Gateway            string            `json:"gateway,omitempty"`
	AuxiliaryAddresses map[string]string `json:"auxiliaryAddresses,omitempty"`
}
type NetworkIPAM struct {
	Driver string              `json:"driver"`
	Config []NetworkIPAMConfig `json:"config"`
}
type NetworkContainer struct {
	Name        string `json:"name"`
	EndpointID  string `json:"endpointId,omitempty"`
	MacAddress  string `json:"macAddress,omitempty"`
	IPv4Address string `json:"ipv4Address"`
	IPv6Address string `json:"ipv6Address,omitempty"`
}
type NetworkSummary struct {
	ID         string                      `json:"id"`
	Name       string                      `json:"name"`
	CreatedAt  time.Time                   `json:"createdAt"`
	Scope      string                      `json:"scope"`
	Driver     string                      `json:"driver"`
	EnableIPv4 bool                        `json:"enableIPv4"`
	EnableIPv6 bool                        `json:"enableIPv6"`
	Internal   bool                        `json:"internal"`
	Attachable bool                        `json:"attachable"`
	Ingress    bool                        `json:"ingress"`
	IPAM       NetworkIPAM                 `json:"ipam"`
	Options    map[string]string           `json:"options"`
	Containers map[string]NetworkContainer `json:"containers"`
	Labels     map[string]string           `json:"labels"`
}
type NetworkListResponse struct {
	Networks []NetworkSummary `json:"networks"`
}
type ContainerDeleteRequest struct {
	ID       string `json:"id"`
	Force    bool   `json:"force,omitempty"`
	Snapshot bool   `json:"snapshot,omitempty"`
}
type ContainerLogsRequest struct {
	ID     string `json:"id"`
	Stdout bool   `json:"stdout,omitempty"`
	Stderr bool   `json:"stderr,omitempty"`
}
type ContainerLogsResponse struct {
	Stdout    []byte `json:"stdout,omitempty"`
	Stderr    []byte `json:"stderr,omitempty"`
	Truncated bool   `json:"truncated,omitempty"`
}
type ContainerTopRequest struct {
	ID   string   `json:"id"`
	Args []string `json:"args,omitempty"`
}
type ContainerTopResponse struct {
	Titles    []string   `json:"titles"`
	Processes [][]string `json:"processes"`
}
type ContainerStatsRequest struct {
	ID string `json:"id"`
}
type ContainerArchiveRequest struct {
	ID   string `json:"id"`
	Path string `json:"path"`
}
type ContainerArchivePutRequest struct {
	ID                   string `json:"id"`
	Path                 string `json:"path"`
	Data                 []byte `json:"data"`
	NoOverwriteDirNonDir bool   `json:"noOverwriteDirNonDir,omitempty"`
}
type ContainerArchivePath struct {
	Name       string    `json:"name"`
	Size       int64     `json:"size"`
	Mode       int64     `json:"mode"`
	ModifiedAt time.Time `json:"modifiedAt"`
	LinkTarget string    `json:"linkTarget,omitempty"`
}
type ContainerChange struct {
	Path string `json:"path"`
	Kind int    `json:"kind"`
}
type ContainerChangesResponse struct {
	Changes []ContainerChange `json:"changes"`
}
type ContainerStatsResponse struct {
	ID          string              `json:"id"`
	Read        time.Time           `json:"read"`
	PreRead     time.Time           `json:"preread"`
	CPUStats    CPUStats            `json:"cpu_stats"`
	PreCPUStats CPUStats            `json:"precpu_stats"`
	MemoryStats MemoryStats         `json:"memory_stats"`
	Networks    map[string]NetStats `json:"networks,omitempty"`
	BlkioStats  BlkioStats          `json:"blkio_stats"`
	PidsStats   PidsStats           `json:"pids_stats"`
}
type CPUStats struct {
	CPUUsage       CPUUsage       `json:"cpu_usage"`
	SystemCPUUsage uint64         `json:"system_cpu_usage"`
	OnlineCPUs     int            `json:"online_cpus"`
	ThrottlingData ThrottlingData `json:"throttling_data"`
}
type CPUUsage struct {
	TotalUsage   uint64 `json:"total_usage"`
	InKernelMode uint64 `json:"usage_in_kernelmode"`
	InUserMode   uint64 `json:"usage_in_usermode"`
}
type ThrottlingData struct {
	ThrottledPeriods  uint64 `json:"throttled_periods"`
	ThrottledTime     uint64 `json:"throttled_time"`
	ThrottlingPeriods uint64 `json:"throttling_periods"`
}
type MemoryStats struct {
	Usage uint64            `json:"usage,omitempty"`
	Limit uint64            `json:"limit,omitempty"`
	Stats map[string]uint64 `json:"stats,omitempty"`
}
type NetStats struct {
	RXBytes   uint64 `json:"rx_bytes"`
	RXPackets uint64 `json:"rx_packets"`
	RXErrors  uint64 `json:"rx_errors"`
	RXDropped uint64 `json:"rx_dropped"`
	TXBytes   uint64 `json:"tx_bytes"`
	TXPackets uint64 `json:"tx_packets"`
	TXErrors  uint64 `json:"tx_errors"`
	TXDropped uint64 `json:"tx_dropped"`
}
type BlkioStats struct {
	IOServiceBytesRecursive []BlkioEntry `json:"io_service_bytes_recursive,omitempty"`
}
type BlkioEntry struct {
	Major uint64 `json:"major"`
	Minor uint64 `json:"minor"`
	Op    string `json:"op"`
	Value uint64 `json:"value"`
}
type PidsStats struct {
	Current uint64 `json:"current,omitempty"`
}
type ContainerExecRequest struct {
	ID       string   `json:"id"`
	ExecID   string   `json:"execId"`
	Args     []string `json:"args"`
	Env      []string `json:"env,omitempty"`
	Cwd      string   `json:"cwd,omitempty"`
	User     string   `json:"user,omitempty"`
	Terminal bool     `json:"terminal,omitempty"`
}
type ExecResizeRequest struct {
	ID     string `json:"id"`
	Width  uint32 `json:"width"`
	Height uint32 `json:"height"`
}
type Container struct {
	ID             string            `json:"id"`
	Image          string            `json:"image"`
	Status         string            `json:"status"`
	PID            uint32            `json:"pid,omitempty"`
	ExitCode       *uint32           `json:"exitCode,omitempty"`
	CreatedAt      time.Time         `json:"createdAt"`
	PublishedPorts []PublishedPort   `json:"publishedPorts,omitempty"`
	Metadata       ContainerMetadata `json:"metadata,omitempty"`
}
type ContainerListResponse struct {
	Containers []Container `json:"containers"`
}
type ContainerResponse struct {
	Container Container `json:"container"`
}
type ContainerExitEvent struct {
	ID       string    `json:"id"`
	ExitCode uint32    `json:"exitCode"`
	ExitedAt time.Time `json:"exitedAt"`
}
