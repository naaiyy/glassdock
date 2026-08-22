package backend

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"net"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/glassdock/glassdock/guest/internal/api"
)

const (
	bridgeName       = "glassdock0"
	bridgeCIDR       = "10.88.0.1/16"
	networkCIDR      = "10.88.0.0/16"
	defaultNetworkID = "bridge"
)

type networkCommandRunner interface {
	Run(name string, args ...string) error
}

type networkNamespaceOperations interface {
	Create(name, hostVeth, containerVeth, address string) error
	Delete(name string) error
}

type networkAttachmentOperations interface {
	Attach(namespace, bridge, hostVeth, containerVeth, address string, prefix int, interfaceName string) error
	Detach(namespace, interfaceName string) error
}

type commandRunner struct{}

func (commandRunner) Run(name string, args ...string) error {
	output, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}
	return nil
}

type containerNetwork struct {
	name       string
	identity   string
	hostname   string
	address    string
	guestPorts []api.PublishedPort
	endpoints  map[string]*networkEndpoint
}

type networkEndpoint struct {
	networkID     string
	interfaceName string
	endpointID    string
	address       string
	ipv6Address   string
	aliases       []string
}

type NetworkEndpoint struct {
	ContainerID string
	EndpointID  string
	Address     string
	IPv6Address string
}

type managedNetwork struct {
	id         string
	name       string
	bridge     string
	subnet     *net.IPNet
	gateway    string
	driver     string
	scope      string
	createdAt  time.Time
	labels     map[string]string
	options    map[string]string
	internal   bool
	enableIPv4 bool
	enableIPv6 bool
	attachable bool
	ingress    bool
	ipamDriver string
	ipRange    *net.IPNet
	auxiliary  map[string]string
	containers map[string]*networkEndpoint
}

// NetworkManager owns one bridge and one preconfigured network namespace per
// container. The namespace exists before runc starts the process, so outbound
// networking is ready when the process executes its first instruction.
type NetworkManager struct {
	mu          sync.Mutex
	runner      networkCommandRunner
	namespaces  networkNamespaceOperations
	initialized bool
	nextAddress uint32
	nextPort    uint16
	containers  map[string]*containerNetwork
	networks    map[string]*managedNetwork
	nextSubnet  uint8
}

func (m *NetworkManager) Path(id string) string {
	return "/run/netns/" + networkName(id)
}

func NewNetworkManager(runner networkCommandRunner) *NetworkManager {
	return newNetworkManager(runner, nativeNetworkNamespaceOperations{})
}

func newNetworkManager(runner networkCommandRunner, namespaces networkNamespaceOperations) *NetworkManager {
	return &NetworkManager{
		runner: runner, namespaces: namespaces, nextAddress: 2, nextPort: 41000,
		containers: make(map[string]*containerNetwork), networks: make(map[string]*managedNetwork), nextSubnet: 89,
	}
}

func (m *NetworkManager) Initialize() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.initialize()
}

func (m *NetworkManager) Create(id string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if existing := m.containers[id]; existing != nil {
		return "/run/netns/" + existing.name, nil
	}
	if err := m.initialize(); err != nil {
		return "", err
	}
	if m.nextAddress >= 65535 {
		return "", errors.New("container bridge address space is exhausted")
	}
	defaultNetwork, err := m.ensureDefaultNetwork()
	if err != nil {
		return "", err
	}
	name := networkName(id)
	address := fmt.Sprintf("10.88.%d.%d", m.nextAddress/256, m.nextAddress%256)
	m.nextAddress++
	hostVeth := "vh" + name[2:]
	containerVeth := "vc" + name[2:]
	if err := m.namespaces.Create(name, hostVeth, containerVeth, address); err != nil {
		_ = m.namespaces.Delete(name)
		return "", err
	}
	endpoint := &networkEndpoint{
		networkID: defaultNetwork.id, interfaceName: "eth0", endpointID: endpointName(defaultNetwork.id, id),
		address: address,
	}
	m.containers[id] = &containerNetwork{
		name: name, address: address, endpoints: map[string]*networkEndpoint{defaultNetwork.id: endpoint},
	}
	defaultNetwork.containers[id] = endpoint
	return "/run/netns/" + name, nil
}

func (m *NetworkManager) CreateNetwork(request api.NetworkCreateRequest) (api.NetworkResource, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := validateNetworkName(request.Name); err != nil {
		return api.NetworkResource{}, err
	}
	if request.Driver != "" && request.Driver != "bridge" && request.Driver != "nat" {
		return api.NetworkResource{}, fmt.Errorf("unsupported network driver %q", request.Driver)
	}
	if existing := m.networkByNameLocked(request.Name); existing != nil {
		return api.NetworkResource{}, fmt.Errorf("network %s already exists", request.Name)
	}
	if _, err := m.ensureDefaultNetwork(); err != nil {
		return api.NetworkResource{}, err
	}
	requestedSubnet, requestedGateway := request.Subnet, request.Gateway
	requestedIPRange := ""
	requestedAuxiliary := map[string]string{}
	ipamDriver := "default"
	if request.IPAM != nil {
		if request.IPAM.Driver != "" {
			ipamDriver = request.IPAM.Driver
		}
		if len(request.IPAM.Config) > 0 {
			config := request.IPAM.Config[0]
			if config.Subnet != "" {
				requestedSubnet = config.Subnet
			}
			if config.Gateway != "" {
				requestedGateway = config.Gateway
			}
			requestedIPRange = config.IPRange
			requestedAuxiliary = cloneStringMap(config.AuxiliaryAddresses)
		}
	}
	subnet, gateway, err := m.allocateSubnetLocked(requestedSubnet, requestedGateway)
	if err != nil {
		return api.NetworkResource{}, err
	}
	id := networkID(request.Name, subnet.String())
	bridge := networkBridgeName(id)
	var ipRange *net.IPNet
	if requestedIPRange != "" {
		_, parsed, parseErr := net.ParseCIDR(requestedIPRange)
		if parseErr != nil || parsed.IP.To4() == nil || !subnet.Contains(parsed.IP) || !subnet.Contains(lastIP(parsed)) {
			return api.NetworkResource{}, fmt.Errorf("invalid IP range %q for subnet %s", requestedIPRange, subnet)
		}
		ipRange = parsed
	}
	for name, address := range requestedAuxiliary {
		parsed := net.ParseIP(address).To4()
		if parsed == nil || !subnet.Contains(parsed) || parsed.String() == gateway {
			return api.NetworkResource{}, fmt.Errorf("invalid auxiliary address %q for subnet %s", address, subnet)
		}
		requestedAuxiliary[name] = parsed.String()
	}
	if err := m.createBridge(bridge, subnet, gateway, request.Internal); err != nil {
		return api.NetworkResource{}, err
	}
	driver := valueOrNetwork(request.Driver, "bridge")
	if driver == "default" {
		driver = "bridge"
	}
	scope := valueOrNetwork(request.Scope, "local")
	enableIPv4 := true
	if request.EnableIPv4 != nil {
		enableIPv4 = *request.EnableIPv4
	}
	attachable := true
	if request.Attachable != nil {
		attachable = *request.Attachable
	}
	ingress := false
	if request.Ingress != nil {
		ingress = *request.Ingress
	}
	network := &managedNetwork{
		id: id, name: request.Name, bridge: bridge, subnet: subnet, gateway: gateway,
		driver: driver, scope: scope, createdAt: time.Now().UTC(), labels: cloneStringMap(request.Labels),
		options: cloneStringMap(request.Options), internal: request.Internal, enableIPv4: enableIPv4,
		enableIPv6: request.EnableIPv6, attachable: attachable, ingress: ingress, ipamDriver: ipamDriver,
		ipRange: ipRange, auxiliary: requestedAuxiliary,
		containers: make(map[string]*networkEndpoint),
	}
	m.networks[id] = network
	return m.networkResourceLocked(network), nil
}

func (m *NetworkManager) ListNetworks() []api.NetworkResource {
	m.mu.Lock()
	defer m.mu.Unlock()
	result := make([]api.NetworkResource, 0, len(m.networks))
	for _, network := range m.networks {
		result = append(result, m.networkResourceLocked(network))
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result
}

// Summaries preserves the original guest protocol view while the richer
// network resource is used by the lifecycle API.
func (m *NetworkManager) Summaries(containerNames map[string]string) []api.NetworkSummary {
	resources := m.ListNetworks()
	result := make([]api.NetworkSummary, 0, len(resources))
	for _, resource := range resources {
		prefix := ""
		if len(resource.IPAM.Config) > 0 {
			if _, subnet, err := net.ParseCIDR(resource.IPAM.Config[0].Subnet); err == nil {
				bits, _ := subnet.Mask.Size()
				prefix = fmt.Sprintf("/%d", bits)
			}
		}
		containers := make(map[string]api.NetworkContainer, len(resource.Containers))
		for id, endpoint := range resource.Containers {
			name := endpoint.Name
			if override := containerNames[id]; override != "" {
				name = override
			}
			containers[id] = api.NetworkContainer{
				Name: name, EndpointID: endpoint.EndpointID, IPv4Address: endpoint.IPv4Address + prefix,
			}
		}
		result = append(result, api.NetworkSummary{
			ID: resource.ID, Name: resource.Name, CreatedAt: resource.CreatedAt, Scope: resource.Scope,
			Driver: resource.Driver, EnableIPv4: resource.EnableIPv4, EnableIPv6: resource.EnableIPv6,
			Internal: resource.Internal, Attachable: resource.Attachable, Ingress: resource.Ingress,
			IPAM: resource.IPAM, Options: cloneStringMap(resource.Options), Containers: containers,
			Labels: cloneStringMap(resource.Labels),
		})
	}
	return result
}

func (m *NetworkManager) Connect(
	networkID, containerID, containerName, ipv4Address, ipv6Address string, running bool,
) error {
	// A container namespace stays alive for the full container lifetime. The
	// native attachment implementation can therefore add and remove veth pairs
	// while the init task is running, matching Docker's hot-connect behavior.
	_ = running
	_, err := m.ConnectNetwork(api.NetworkConnectRequest{
		NetworkID: networkID, ContainerID: containerID, Aliases: []string{containerName},
		IPv4Address: ipv4Address, IPv6Address: ipv6Address,
	})
	return err
}

func (m *NetworkManager) Disconnect(networkID, containerID string, force bool) error {
	_, err := m.DisconnectNetwork(api.NetworkDisconnectRequest{
		NetworkID: networkID, ContainerID: containerID, Force: force,
	})
	return err
}

func (m *NetworkManager) Endpoints() []NetworkEndpoint {
	m.mu.Lock()
	defer m.mu.Unlock()
	ids := make([]string, 0, len(m.containers))
	for id := range m.containers {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	result := make([]NetworkEndpoint, 0, len(ids))
	for _, id := range ids {
		container := m.containers[id]
		endpoint := container.endpoints[defaultNetworkID]
		if endpoint == nil {
			continue
		}
		result = append(result, NetworkEndpoint{
			ContainerID: id, EndpointID: endpoint.endpointID, Address: endpoint.address,
			IPv6Address: endpoint.ipv6Address,
		})
	}
	return result
}

func (m *NetworkManager) CreatedAt() time.Time {
	m.mu.Lock()
	defer m.mu.Unlock()
	if network := m.networks[defaultNetworkID]; network != nil {
		return network.createdAt
	}
	return time.Time{}
}

func (m *NetworkManager) InspectNetwork(id string) (api.NetworkResource, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	network := m.resolveNetworkLocked(id)
	if network == nil {
		return api.NetworkResource{}, fmt.Errorf("network %s not found", id)
	}
	return m.networkResourceLocked(network), nil
}

func (m *NetworkManager) DeleteNetwork(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	network := m.resolveNetworkLocked(id)
	if network == nil {
		return fmt.Errorf("network %s not found", id)
	}
	if network.id == defaultNetworkID || network.name == "bridge" {
		return errors.New("default bridge network cannot be removed")
	}
	if len(network.containers) != 0 {
		return fmt.Errorf("network %s has active endpoints", network.name)
	}
	if err := m.runner.Run("ip", "link", "delete", network.bridge); err != nil {
		return err
	}
	delete(m.networks, network.id)
	return nil
}

func (m *NetworkManager) PruneNetworks(filters map[string][]string) api.NetworkPruneResponse {
	m.mu.Lock()
	defer m.mu.Unlock()
	result := api.NetworkPruneResponse{NetworksDeleted: []string{}, Errors: map[string]string{}}
	ids := make([]string, 0, len(m.networks))
	for id := range m.networks {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		network := m.networks[id]
		if network.id == defaultNetworkID || len(network.containers) != 0 || !matchesNetworkFilters(network, filters) {
			continue
		}
		if err := m.runner.Run("ip", "link", "delete", network.bridge); err != nil {
			result.Errors[id] = err.Error()
			continue
		}
		delete(m.networks, id)
		result.NetworksDeleted = append(result.NetworksDeleted, id)
	}
	return result
}

func (m *NetworkManager) ConnectNetwork(request api.NetworkConnectRequest) (api.NetworkResource, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	network := m.resolveNetworkLocked(request.NetworkID)
	if network == nil {
		return api.NetworkResource{}, fmt.Errorf("network %s not found", request.NetworkID)
	}
	container := m.containers[request.ContainerID]
	if container == nil {
		return api.NetworkResource{}, fmt.Errorf("container %s not found", request.ContainerID)
	}
	if _, exists := network.containers[request.ContainerID]; exists {
		return api.NetworkResource{}, fmt.Errorf("container %s is already connected to network %s", request.ContainerID, network.name)
	}
	if request.IPv6Address != "" {
		if !network.enableIPv6 {
			return api.NetworkResource{}, fmt.Errorf("network %s does not have IPv6 enabled", network.name)
		}
		parsed := net.ParseIP(request.IPv6Address)
		if parsed == nil || parsed.To4() != nil {
			return api.NetworkResource{}, fmt.Errorf("invalid IPv6 address %q", request.IPv6Address)
		}
	}
	address := ""
	var err error
	if network.enableIPv4 {
		address, err = m.allocateAddressLocked(network, request.IPv4Address)
		if err != nil {
			return api.NetworkResource{}, err
		}
	} else if request.IPv4Address != "" {
		return api.NetworkResource{}, fmt.Errorf("network %s does not have IPv4 enabled", network.name)
	}
	interfaceName := fmt.Sprintf("eth%d", len(container.endpoints))
	endpointID := endpointName(network.id, request.ContainerID)
	hostVeth := "vh" + endpointID[:10]
	containerVeth := "vc" + endpointID[:10]
	prefix, _ := network.subnet.Mask.Size()
	if err := m.attachNamespace(container.name, network.bridge, hostVeth, containerVeth, address, prefix, interfaceName); err != nil {
		return api.NetworkResource{}, err
	}
	aliases := normalizeAliases(request.Aliases, container)
	endpoint := &networkEndpoint{
		networkID: network.id, interfaceName: interfaceName, endpointID: endpointID,
		address: address, ipv6Address: normalizeIPv6Address(network, request.IPv6Address), aliases: aliases,
	}
	container.endpoints[network.id] = endpoint
	network.containers[request.ContainerID] = endpoint
	return m.networkResourceLocked(network), nil
}

func (m *NetworkManager) DisconnectNetwork(request api.NetworkDisconnectRequest) (api.NetworkResource, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	network := m.resolveNetworkLocked(request.NetworkID)
	if network == nil {
		return api.NetworkResource{}, fmt.Errorf("network %s not found", request.NetworkID)
	}
	container := m.containers[request.ContainerID]
	if container == nil {
		return api.NetworkResource{}, fmt.Errorf("container %s not found", request.ContainerID)
	}
	endpoint := network.containers[request.ContainerID]
	if endpoint == nil {
		return api.NetworkResource{}, fmt.Errorf("container %s is not connected to network %s", request.ContainerID, network.name)
	}
	if err := m.detachNamespace(container.name, endpoint.interfaceName); err != nil {
		return api.NetworkResource{}, err
	}
	delete(network.containers, request.ContainerID)
	delete(container.endpoints, network.id)
	return m.networkResourceLocked(network), nil
}

func (m *NetworkManager) SetContainerIdentity(id, name, hostname string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if container := m.containers[id]; container != nil {
		if name != "" {
			container.identity = name
		}
		if hostname != "" {
			container.hostname = hostname
		}
	}
}

func (m *NetworkManager) ContainerIDs() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	ids := make([]string, 0, len(m.containers))
	for id := range m.containers {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

func (m *NetworkManager) HostsFile(id string) (string, []string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	container := m.containers[id]
	if container == nil {
		return "", nil, fmt.Errorf("container %s not found", id)
	}
	type hostEntry struct{ address, name string }
	entries := make([]hostEntry, 0)
	nameservers := make([]string, 0)
	for _, network := range m.networks {
		if network.containers[id] == nil {
			continue
		}
		if network.gateway != "" {
			nameservers = append(nameservers, network.gateway)
		}
		for containerID, endpoint := range network.containers {
			other := m.containers[containerID]
			if other == nil {
				continue
			}
			name := other.identity
			if name == "" {
				name = containerID
			}
			entries = append(entries, hostEntry{address: endpoint.address, name: name})
			if other.hostname != "" && other.hostname != name {
				entries = append(entries, hostEntry{address: endpoint.address, name: other.hostname})
			}
			for _, alias := range endpoint.aliases {
				entries = append(entries, hostEntry{address: endpoint.address, name: alias})
			}
		}
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].name == entries[j].name {
			return entries[i].address < entries[j].address
		}
		return entries[i].name < entries[j].name
	})
	var builder strings.Builder
	builder.WriteString("# glassdock managed hosts begin\n")
	seen := make(map[string]struct{})
	for _, entry := range entries {
		key := entry.address + " " + entry.name
		if _, exists := seen[key]; exists {
			continue
		}
		seen[key] = struct{}{}
		builder.WriteString(entry.address)
		builder.WriteByte(' ')
		builder.WriteString(entry.name)
		builder.WriteByte('\n')
	}
	builder.WriteString("# glassdock managed hosts end\n")
	return builder.String(), uniqueStrings(nameservers), nil
}

func (m *NetworkManager) ensureDefaultNetwork() (*managedNetwork, error) {
	if network := m.networks[defaultNetworkID]; network != nil {
		return network, nil
	}
	if err := m.initialize(); err != nil {
		return nil, err
	}
	_, subnet, err := net.ParseCIDR(networkCIDR)
	if err != nil {
		return nil, err
	}
	network := &managedNetwork{
		id: defaultNetworkID, name: "bridge", bridge: bridgeName, subnet: subnet,
		gateway: "10.88.0.1", driver: "bridge", createdAt: time.Unix(0, 0).UTC(),
		scope: "local", labels: map[string]string{}, options: map[string]string{}, enableIPv4: true,
		enableIPv6: false, attachable: false, ipamDriver: "default", auxiliary: map[string]string{},
		containers: make(map[string]*networkEndpoint),
	}
	m.networks[network.id] = network
	return network, nil
}

func (m *NetworkManager) networkByNameLocked(name string) *managedNetwork {
	for _, network := range m.networks {
		if network.name == name {
			return network
		}
	}
	return nil
}

func (m *NetworkManager) resolveNetworkLocked(reference string) *managedNetwork {
	if network := m.networks[reference]; network != nil {
		return network
	}
	return m.networkByNameLocked(reference)
}

func (m *NetworkManager) networkResourceLocked(network *managedNetwork) api.NetworkResource {
	containers := make(map[string]api.NetworkEndpoint, len(network.containers))
	for id, endpoint := range network.containers {
		container := m.containers[id]
		name := id
		if container != nil && container.identity != "" {
			name = container.identity
		}
		containers[id] = api.NetworkEndpoint{
			Name: name, EndpointID: endpoint.endpointID, IPv4Address: endpoint.address,
			IPv6Address: endpoint.ipv6Address, Gateway: network.gateway,
			Aliases: append([]string(nil), endpoint.aliases...),
		}
	}
	return api.NetworkResource{
		ID: network.id, Name: network.name, CreatedAt: network.createdAt, Scope: valueOrNetwork(network.scope, "local"),
		Driver: network.driver, EnableIPv4: network.enableIPv4, EnableIPv6: network.enableIPv6,
		Internal: network.internal, Attachable: network.attachable, Ingress: network.ingress,
		IPAM: api.NetworkIPAM{
			Driver: valueOrNetwork(network.ipamDriver, "default"),
			Config: []api.NetworkIPAMConfig{{
				Subnet: network.subnet.String(), IPRange: ipRangeString(network.ipRange),
				Gateway: network.gateway, AuxiliaryAddresses: cloneStringMap(network.auxiliary),
			}},
		},
		Subnet: network.subnet.String(), Gateway: network.gateway,
		Options: cloneStringMap(network.options), Labels: cloneStringMap(network.labels), Containers: containers,
	}
}

func (m *NetworkManager) allocateSubnetLocked(requested, requestedGateway string) (*net.IPNet, string, error) {
	var subnet *net.IPNet
	var err error
	if requested != "" {
		_, subnet, err = net.ParseCIDR(requested)
		if err != nil || subnet.IP.To4() == nil {
			return nil, "", fmt.Errorf("invalid IPv4 subnet %q", requested)
		}
	} else {
		for attempts := 0; attempts < 166; attempts++ {
			candidate := fmt.Sprintf("10.%d.0.0/16", m.nextSubnet)
			m.nextSubnet++
			_, candidateSubnet, parseErr := net.ParseCIDR(candidate)
			if parseErr == nil && !m.subnetOverlapsLocked(candidateSubnet) {
				subnet = candidateSubnet
				break
			}
		}
		if subnet == nil {
			return nil, "", errors.New("network address space is exhausted")
		}
	}
	if m.subnetOverlapsLocked(subnet) {
		return nil, "", fmt.Errorf("network subnet %s overlaps an existing network", subnet.String())
	}
	gateway := requestedGateway
	if gateway == "" {
		gatewayIP := append(net.IP(nil), subnet.IP.To4()...)
		gatewayIP[3]++
		gateway = gatewayIP.String()
	}
	parsedGateway := net.ParseIP(gateway).To4()
	if parsedGateway == nil || !subnet.Contains(parsedGateway) || parsedGateway.Equal(subnet.IP) {
		return nil, "", fmt.Errorf("gateway %q is outside subnet %s", gateway, subnet.String())
	}
	return subnet, gateway, nil
}

func (m *NetworkManager) subnetOverlapsLocked(candidate *net.IPNet) bool {
	for _, network := range m.networks {
		if network.subnet.Contains(candidate.IP) || candidate.Contains(network.subnet.IP) {
			return true
		}
	}
	return false
}

func (m *NetworkManager) allocateAddressLocked(network *managedNetwork, requested string) (string, error) {
	pool := network.subnet
	if network.ipRange != nil {
		pool = network.ipRange
	}
	if requested != "" {
		address := net.ParseIP(requested).To4()
		if address == nil || !pool.Contains(address) || address.String() == network.gateway {
			return "", fmt.Errorf("IPv4 address %q is outside network %s", requested, network.name)
		}
		for _, endpoint := range network.containers {
			if endpoint.address == address.String() {
				return "", fmt.Errorf("IPv4 address %s is already in use", requested)
			}
		}
		return address.String(), nil
	}
	base := binaryIP(pool.IP.To4())
	first := binaryIP(net.ParseIP(network.gateway).To4()) + 1
	if !pool.Contains(net.ParseIP(network.gateway).To4()) {
		first = base + 1
	}
	maskSize, bits := pool.Mask.Size()
	limit := uint32(1) << uint32(bits-maskSize)
	for offset := first - base; offset < limit-1; offset++ {
		candidate := uint32ToIP(base + offset).String()
		used := false
		for _, endpoint := range network.containers {
			if endpoint.address == candidate {
				used = true
				break
			}
		}
		if !used && candidate != network.gateway {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("network %s address space is exhausted", network.name)
}

func (m *NetworkManager) createBridge(bridge string, subnet *net.IPNet, gateway string, internal bool) error {
	prefix, _ := subnet.Mask.Size()
	commands := [][]string{
		{"ip", "link", "add", bridge, "type", "bridge"},
		{"ip", "addr", "add", fmt.Sprintf("%s/%d", gateway, prefix), "dev", bridge},
		{"ip", "link", "set", bridge, "up"},
	}
	if !internal {
		commands = append(commands,
			[]string{"iptables", "-t", "nat", "-A", "POSTROUTING", "-s", subnet.String(), "!", "-o", bridge, "-j", "MASQUERADE"},
			[]string{"iptables", "-A", "FORWARD", "-i", bridge, "-j", "ACCEPT"},
			[]string{"iptables", "-A", "FORWARD", "-o", bridge, "-m", "conntrack", "--ctstate", "RELATED,ESTABLISHED", "-j", "ACCEPT"},
		)
	}
	for _, command := range commands {
		if err := m.runner.Run(command[0], command[1:]...); err != nil {
			_ = m.runner.Run("ip", "link", "delete", bridge)
			return err
		}
	}
	return nil
}

func (m *NetworkManager) attachNamespace(namespace, bridge, hostVeth, containerVeth, address string, maskSize int, interfaceName string) error {
	if operations, ok := m.namespaces.(networkAttachmentOperations); ok {
		return operations.Attach(namespace, bridge, hostVeth, containerVeth, address, maskSize, interfaceName)
	}
	return m.runner.Run(
		"netlink", "attach", namespace, bridge, hostVeth, containerVeth,
		"addr", fmt.Sprintf("%s/%d", address, maskSize), "dev", interfaceName,
	)
}

func (m *NetworkManager) detachNamespace(namespace, interfaceName string) error {
	if operations, ok := m.namespaces.(networkAttachmentOperations); ok {
		return operations.Detach(namespace, interfaceName)
	}
	return m.runner.Run("netlink", "detach", namespace, interfaceName)
}

func matchesNetworkFilters(network *managedNetwork, filters map[string][]string) bool {
	for key, values := range filters {
		if len(values) == 0 {
			continue
		}
		matched := false
		for _, value := range values {
			switch key {
			case "dangling":
				want := value == "true" || value == "1"
				matched = want == (len(network.containers) == 0)
			case "driver":
				matched = strings.EqualFold(network.driver, value)
			case "id":
				matched = strings.HasPrefix(network.id, value)
			case "name":
				matched = strings.Contains(network.name, value)
			case "label":
				parts := strings.SplitN(value, "=", 2)
				label, exists := network.labels[parts[0]]
				matched = exists && (len(parts) == 1 || label == parts[1])
			case "type":
				matched = value == "custom"
			default:
				matched = false
			}
			if matched {
				break
			}
		}
		if !matched {
			return false
		}
	}
	return true
}

func normalizeAliases(requested []string, container *containerNetwork) []string {
	values := make([]string, 0, len(requested)+2)
	if container.identity != "" {
		values = append(values, container.identity)
	}
	for _, value := range requested {
		if value != "" {
			values = append(values, value)
		}
	}
	return uniqueStrings(values)
}

func uniqueStrings(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	result := make([]string, 0, len(values))
	for _, value := range values {
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	return result
}

func cloneStringMap(input map[string]string) map[string]string {
	if len(input) == 0 {
		return map[string]string{}
	}
	result := make(map[string]string, len(input))
	for key, value := range input {
		result[key] = value
	}
	return result
}

func valueOrNetwork(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

func ipRangeString(value *net.IPNet) string {
	if value == nil {
		return ""
	}
	return value.String()
}

func lastIP(network *net.IPNet) net.IP {
	last := append(net.IP(nil), network.IP.To4()...)
	mask := network.Mask
	for index := range last {
		last[index] |= ^mask[len(mask)-len(last)+index]
	}
	return last
}

func normalizeIPv6Address(network *managedNetwork, requested string) string {
	if requested == "" || !network.enableIPv6 {
		return ""
	}
	parsed := net.ParseIP(requested)
	if parsed == nil || parsed.To4() != nil {
		return ""
	}
	return parsed.String()
}

func validateNetworkName(name string) error {
	if name == "" || len(name) > 255 {
		return errors.New("network name is required and must be at most 255 characters")
	}
	for _, character := range name {
		if !(character == '-' || character == '_' || character == '.' || character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' || character >= '0' && character <= '9') {
			return fmt.Errorf("invalid network name %q", name)
		}
	}
	return nil
}

func (m *NetworkManager) Publish(id string, requested []api.PublishedPort) ([]api.PublishedPort, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	network := m.containers[id]
	if network == nil {
		if len(requested) == 0 {
			return nil, nil
		}
		return nil, fmt.Errorf("private network does not exist for container %s", id)
	}
	if len(network.guestPorts) != 0 {
		if !publishedRequestMatches(network.guestPorts, requested) {
			return nil, fmt.Errorf("container %s already has a different published-port set", id)
		}
		return append([]api.PublishedPort(nil), network.guestPorts...), nil
	}
	published, err := m.normalizePublishedPorts(requested)
	if err != nil {
		return nil, err
	}
	installed := make([]api.PublishedPort, 0, len(published))
	selected := make(map[string]struct{}, len(published))
	for _, port := range published {
		key := port.Protocol + ":" + strconv.Itoa(int(port.GuestPort))
		if _, duplicate := selected[key]; duplicate {
			rollbackError := m.removeRules(network, installed)
			return nil, errors.Join(
				fmt.Errorf("published %s port %d is duplicated", port.Protocol, port.GuestPort),
				rollbackError,
			)
		}
		if conflictID, conflict := m.portOwner(port.GuestPort, port.Protocol); conflict {
			rollbackError := m.removeRules(network, installed)
			return nil, errors.Join(
				fmt.Errorf("published %s port %d is already owned by container %s", port.Protocol, port.GuestPort, conflictID),
				rollbackError,
			)
		}
		if err := m.addRules(network, port); err != nil {
			return nil, errors.Join(err, m.removeRules(network, installed))
		}
		installed = append(installed, port)
		selected[key] = struct{}{}
	}
	network.guestPorts = published
	return append([]api.PublishedPort(nil), published...), nil
}

func (m *NetworkManager) normalizePublishedPorts(requested []api.PublishedPort) ([]api.PublishedPort, error) {
	published := make([]api.PublishedPort, 0, len(requested))
	for _, port := range requested {
		protocol := strings.ToLower(port.Protocol)
		if protocol == "" {
			protocol = "tcp"
		}
		if (protocol != "tcp" && protocol != "udp") || port.ContainerPort == 0 {
			return nil, fmt.Errorf("unsupported published port %d/%s", port.ContainerPort, protocol)
		}
		guestPort := port.GuestPort
		if guestPort == 0 {
			var found bool
			for attempts := 0; attempts < 65535-41000+1; attempts++ {
				candidate := m.nextPort
				m.nextPort++
				if m.nextPort < 41000 {
					m.nextPort = 41000
				}
				if _, conflict := m.portOwner(candidate, protocol); !conflict {
					guestPort = candidate
					found = true
					break
				}
			}
			if !found {
				return nil, errors.New("published guest port range is exhausted")
			}
		}
		published = append(published, api.PublishedPort{ContainerPort: port.ContainerPort, GuestPort: guestPort, Protocol: protocol, HostSource: port.HostSource})
	}
	return published, nil
}

func (m *NetworkManager) portOwner(guestPort uint16, protocol string) (string, bool) {
	for id, network := range m.containers {
		for _, published := range network.guestPorts {
			if published.GuestPort == guestPort && published.Protocol == protocol {
				return id, true
			}
		}
	}
	return "", false
}

func (m *NetworkManager) Published(id string) []api.PublishedPort {
	m.mu.Lock()
	defer m.mu.Unlock()
	if network := m.containers[id]; network != nil {
		return append([]api.PublishedPort(nil), network.guestPorts...)
	}
	return nil
}

func (m *NetworkManager) PublishedTCPDestination(guestPort uint16) (string, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, network := range m.containers {
		for _, published := range network.guestPorts {
			if published.Protocol == "tcp" && published.GuestPort == guestPort {
				return net.JoinHostPort(
					network.address,
					strconv.Itoa(int(published.ContainerPort)),
				), true
			}
		}
	}
	return "", false
}

func (m *NetworkManager) Delete(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	network := m.containers[id]
	if network == nil {
		return nil
	}
	if err := m.removeRules(network, network.guestPorts); err != nil {
		return err
	}
	if err := m.namespaces.Delete(network.name); err != nil {
		return err
	}
	for networkID, endpoint := range network.endpoints {
		if managed := m.networks[networkID]; managed != nil {
			delete(managed.containers, id)
		}
		_ = endpoint
	}
	delete(m.containers, id)
	return nil
}

func (m *NetworkManager) initialize() error {
	if m.initialized {
		return nil
	}
	commands := []string{
		"ip link add " + bridgeName + " type bridge",
		"ip addr add " + bridgeCIDR + " dev " + bridgeName,
		"ip link set " + bridgeName + " up",
		"sysctl -w net.ipv4.ip_forward=1",
		"iptables -t nat -A POSTROUTING -s " + networkCIDR + " ! -o " + bridgeName + " -j MASQUERADE",
		"iptables -A FORWARD -i " + bridgeName + " -j ACCEPT",
		"iptables -A FORWARD -o " + bridgeName + " -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT",
	}
	if err := m.runner.Run("sh", "-c", strings.Join(commands, " && ")); err != nil {
		return err
	}
	m.initialized = true
	if m.networks[defaultNetworkID] == nil {
		_, subnet, err := net.ParseCIDR(networkCIDR)
		if err != nil {
			return err
		}
		m.networks[defaultNetworkID] = &managedNetwork{
			id: defaultNetworkID, name: "bridge", bridge: bridgeName, subnet: subnet,
			gateway: "10.88.0.1", driver: "bridge", createdAt: time.Unix(0, 0).UTC(),
			labels: map[string]string{}, options: map[string]string{}, enableIPv4: true,
			enableIPv6: false, attachable: false, ipamDriver: "default",
			auxiliary: map[string]string{}, containers: make(map[string]*networkEndpoint),
		}
	}
	return nil
}

func (m *NetworkManager) addRules(network *containerNetwork, port api.PublishedPort) error {
	rules := publicationRuleArguments("-A", network, port)
	for ruleIndex, rule := range rules {
		if err := m.runner.Run("iptables", rule...); err != nil {
			rollback := publicationRuleArguments("-D", network, port)
			var rollbackError error
			for installedIndex := ruleIndex - 1; installedIndex >= 0; installedIndex-- {
				rollbackError = errors.Join(
					rollbackError,
					m.runner.Run("iptables", rollback[installedIndex]...),
				)
			}
			return errors.Join(err, rollbackError)
		}
	}
	return nil
}

func (m *NetworkManager) removeRules(network *containerNetwork, ports []api.PublishedPort) error {
	var firstError error
	for portIndex := len(ports) - 1; portIndex >= 0; portIndex-- {
		rules := publicationRuleArguments("-D", network, ports[portIndex])
		for ruleIndex := len(rules) - 1; ruleIndex >= 0; ruleIndex-- {
			if err := m.runner.Run("iptables", rules[ruleIndex]...); err != nil && firstError == nil {
				firstError = err
			}
		}
	}
	return firstError
}

func publicationRuleArguments(operation string, network *containerNetwork, port api.PublishedPort) [][]string {
	guestPort := strconv.Itoa(int(port.GuestPort))
	containerPort := strconv.Itoa(int(port.ContainerPort))
	target := network.address + ":" + containerPort
	comment := "glassdock:" + network.name + ":" + port.Protocol + ":" + guestPort
	return [][]string{
		{"-t", "nat", operation, "PREROUTING", "-i", "eth0", "-p", port.Protocol, "--dport", guestPort, "-m", "comment", "--comment", comment, "-j", "DNAT", "--to-destination", target},
		{operation, "FORWARD", "-i", "eth0", "-o", bridgeName, "-p", port.Protocol, "-d", network.address, "--dport", containerPort, "-m", "conntrack", "--ctstate", "NEW,ESTABLISHED", "-m", "comment", "--comment", comment, "-j", "ACCEPT"},
		{operation, "FORWARD", "-i", bridgeName, "-o", "eth0", "-p", port.Protocol, "-s", network.address, "--sport", containerPort, "-m", "conntrack", "--ctstate", "ESTABLISHED", "-m", "comment", "--comment", comment, "-j", "ACCEPT"},
	}
}

func publishedRequestMatches(existing, requested []api.PublishedPort) bool {
	if len(existing) != len(requested) {
		return false
	}
	for index, request := range requested {
		protocol := strings.ToLower(request.Protocol)
		if protocol == "" {
			protocol = "tcp"
		}
		if existing[index].ContainerPort != request.ContainerPort ||
			existing[index].Protocol != protocol ||
			existing[index].HostSource != request.HostSource ||
			(request.GuestPort != 0 && existing[index].GuestPort != request.GuestPort) {
			return false
		}
	}
	return true
}

func networkName(id string) string {
	digest := sha256.Sum256([]byte(id))
	return fmt.Sprintf("st%x", digest[:6])
}

func networkID(name, subnet string) string {
	digest := sha256.Sum256([]byte(name + "\x00" + subnet))
	return fmt.Sprintf("%x", digest[:])
}

func endpointName(networkID, containerID string) string {
	digest := sha256.Sum256([]byte(networkID + "\x00" + containerID))
	return fmt.Sprintf("%x", digest[:6])
}

func networkBridgeName(id string) string {
	return "gd" + id[:10]
}

func binaryIP(address net.IP) uint32 {
	address = address.To4()
	if len(address) != net.IPv4len {
		return 0
	}
	return uint32(address[0])<<24 | uint32(address[1])<<16 | uint32(address[2])<<8 | uint32(address[3])
}

func uint32ToIP(value uint32) net.IP {
	return net.IPv4(byte(value>>24), byte(value>>16), byte(value>>8), byte(value))
}
