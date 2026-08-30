package backend

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net"
	"os"
	"os/exec"
	"path/filepath"
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
	networkStatePath = "/var/lib/containerd/io.glassdock.networks.json"
)

type persistedNetwork struct {
	ID            string            `json:"id"`
	Name          string            `json:"name"`
	Subnet        string            `json:"subnet,omitempty"`
	Gateway       string            `json:"gateway,omitempty"`
	IPv6Subnet    string            `json:"ipv6Subnet,omitempty"`
	IPv6Gateway   string            `json:"ipv6Gateway,omitempty"`
	Driver        string            `json:"driver"`
	Scope         string            `json:"scope"`
	CreatedAt     time.Time         `json:"createdAt"`
	Labels        map[string]string `json:"labels"`
	Options       map[string]string `json:"options"`
	Internal      bool              `json:"internal"`
	EnableIPv4    bool              `json:"enableIPv4"`
	EnableIPv6    bool              `json:"enableIPv6"`
	Attachable    bool              `json:"attachable"`
	Ingress       bool              `json:"ingress"`
	IPAMDriver    string            `json:"ipamDriver"`
	IPRange       string            `json:"ipRange,omitempty"`
	IPv6IPRange   string            `json:"ipv6IpRange,omitempty"`
	Auxiliary     map[string]string `json:"auxiliary,omitempty"`
	IPv6Auxiliary map[string]string `json:"ipv6Auxiliary,omitempty"`
}

type persistedNetworkState struct {
	Networks []persistedNetwork `json:"networks"`
}

type networkCommandRunner interface {
	Run(name string, args ...string) error
}

type networkNamespaceOperations interface {
	Create(name, hostVeth, containerVeth, address string) error
	Delete(name string) error
}

type networkAttachmentOperations interface {
	Attach(
		namespace, bridge, hostVeth, containerVeth string,
		ipv4Address string, ipv4Prefix int,
		ipv6Address string, ipv6Prefix int,
		ipv4Gateway string, ipv6Gateway string,
		interfaceName string,
	) error
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
	id            string
	name          string
	bridge        string
	subnet        *net.IPNet
	gateway       string
	ipv6Subnet    *net.IPNet
	ipv6Gateway   string
	driver        string
	scope         string
	createdAt     time.Time
	labels        map[string]string
	options       map[string]string
	internal      bool
	enableIPv4    bool
	enableIPv6    bool
	attachable    bool
	ingress       bool
	ipamDriver    string
	ipRange       *net.IPNet
	ipv6IPRange   *net.IPNet
	auxiliary     map[string]string
	ipv6Auxiliary map[string]string
	containers    map[string]*networkEndpoint
}

// NetworkManager owns one bridge and one preconfigured network namespace per
// container. The namespace exists before runc starts the process, so outbound
// networking is ready when the process executes its first instruction.
type NetworkManager struct {
	mu             sync.Mutex
	runner         networkCommandRunner
	namespaces     networkNamespaceOperations
	initialized    bool
	nextAddress    uint32
	nextPort       uint16
	containers     map[string]*containerNetwork
	networks       map[string]*managedNetwork
	nextSubnet     uint8
	nextIPv6Subnet uint16
	statePath      string
}

func (m *NetworkManager) Path(id string) string {
	return "/run/netns/" + networkName(id)
}

func NewNetworkManager(runner networkCommandRunner) *NetworkManager {
	manager := newNetworkManager(runner, nativeNetworkNamespaceOperations{})
	manager.statePath = networkStatePath
	return manager
}

func newNetworkManager(runner networkCommandRunner, namespaces networkNamespaceOperations) *NetworkManager {
	return &NetworkManager{
		runner: runner, namespaces: namespaces, nextAddress: 2, nextPort: 41000,
		containers: make(map[string]*containerNetwork), networks: make(map[string]*managedNetwork),
		nextSubnet: 89, nextIPv6Subnet: 1,
	}
}

func (m *NetworkManager) Initialize() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.initialize()
}

func (m *NetworkManager) Create(id string) (string, error) {
	return m.createWithIdentityAndAddresses(id, "", "", "", "")
}

// CreateWithIdentity creates the private namespace and records the Docker
// name and hostname while the manager already owns its lock. Container
// creation starts this work in parallel with containerd setup, so assigning
// the identity after Create would contend with the netlink setup and add the
// full namespace-provisioning time to the Docker create response.
func (m *NetworkManager) CreateWithIdentity(id, identity, hostname string) (string, error) {
	return m.createWithIdentityAndAddresses(id, "", "", identity, hostname)
}

// CreateWithAddresses provisions the default private namespace and honors the
// IPAM addresses supplied to docker create/run for the default bridge.
func (m *NetworkManager) CreateWithAddresses(id, ipv4Address, ipv6Address string) (string, error) {
	return m.createWithIdentityAndAddresses(id, ipv4Address, ipv6Address, "", "")
}

// CreateWithIdentityAndAddresses combines Docker identity persistence with
// default-bridge IPAM allocation for the asynchronous create path.
func (m *NetworkManager) CreateWithIdentityAndAddresses(
	id, ipv4Address, ipv6Address, identity, hostname string,
) (string, error) {
	return m.createWithIdentityAndAddresses(id, ipv4Address, ipv6Address, identity, hostname)
}

func (m *NetworkManager) createWithIdentityAndAddresses(
	id, requestedIPv4, requestedIPv6, identity, hostname string,
) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.createLocked(id, requestedIPv4, requestedIPv6, identity, hostname)
}

func (m *NetworkManager) createLocked(
	id, requestedIPv4, requestedIPv6, identity, hostname string,
) (string, error) {
	if existing := m.containers[id]; existing != nil {
		if identity != "" {
			existing.identity = identity
		}
		if hostname != "" {
			existing.hostname = hostname
		}
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
	if requestedIPv6 != "" {
		return "", fmt.Errorf("default bridge network does not have IPv6 enabled")
	}
	address, err := m.allocateAddressLocked(defaultNetwork, requestedIPv4)
	if err != nil {
		return "", err
	}
	if requestedIPv4 == "" {
		m.nextAddress++
	}
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
		name: name, identity: identity, hostname: hostname, address: address,
		endpoints: map[string]*networkEndpoint{defaultNetwork.id: endpoint},
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
	enableIPv4 := true
	if request.EnableIPv4 != nil {
		enableIPv4 = *request.EnableIPv4
	}
	enableIPv6 := request.EnableIPv6
	requestedIPv4Subnet, requestedIPv4Gateway := "", ""
	requestedIPv6Subnet, requestedIPv6Gateway := "", ""
	requestedIPv4Range, requestedIPv6Range := "", ""
	requestedIPv4Auxiliary := map[string]string{}
	requestedIPv6Auxiliary := map[string]string{}
	ipamDriver := "default"

	assignAddress := func(value string, ipv4, ipv6 *string) error {
		if value == "" {
			return nil
		}
		parsed := net.ParseIP(value)
		if parsed == nil {
			return fmt.Errorf("invalid IP address %q", value)
		}
		if parsed.To4() != nil {
			if *ipv4 != "" && *ipv4 != parsed.To4().String() {
				return fmt.Errorf("multiple IPv4 values are not supported: %q", value)
			}
			*ipv4 = parsed.To4().String()
			return nil
		}
		if *ipv6 != "" && *ipv6 != parsed.To16().String() {
			return fmt.Errorf("multiple IPv6 values are not supported: %q", value)
		}
		*ipv6 = parsed.To16().String()
		return nil
	}

	if err := assignAddress(request.Gateway, &requestedIPv4Gateway, &requestedIPv6Gateway); err != nil {
		return api.NetworkResource{}, err
	}
	if request.Subnet != "" {
		_, parsed, parseErr := net.ParseCIDR(request.Subnet)
		if parseErr != nil {
			return api.NetworkResource{}, fmt.Errorf("invalid network subnet %q", request.Subnet)
		}
		if parsed.IP.To4() != nil {
			requestedIPv4Subnet = request.Subnet
		} else {
			requestedIPv6Subnet = request.Subnet
			enableIPv6 = true
		}
	}
	if request.IPAM != nil {
		if request.IPAM.Driver != "" {
			ipamDriver = request.IPAM.Driver
		}
		for _, config := range request.IPAM.Config {
			if config.Subnet == "" {
				return api.NetworkResource{}, errors.New("IPAM config subnet is required")
			}
			_, parsedSubnet, parseErr := net.ParseCIDR(config.Subnet)
			if parseErr != nil {
				return api.NetworkResource{}, fmt.Errorf("invalid IPAM subnet %q", config.Subnet)
			}
			ipv4 := parsedSubnet.IP.To4() != nil
			if ipv4 {
				if requestedIPv4Subnet != "" && requestedIPv4Subnet != config.Subnet {
					return api.NetworkResource{}, errors.New("multiple IPv4 IPAM subnets are not supported")
				}
				requestedIPv4Subnet = config.Subnet
				if err := assignAddress(config.Gateway, &requestedIPv4Gateway, &requestedIPv6Gateway); err != nil {
					return api.NetworkResource{}, err
				}
				requestedIPv4Range = config.IPRange
				requestedIPv4Auxiliary = cloneStringMap(config.AuxiliaryAddresses)
			} else {
				if requestedIPv6Subnet != "" && requestedIPv6Subnet != config.Subnet {
					return api.NetworkResource{}, errors.New("multiple IPv6 IPAM subnets are not supported")
				}
				requestedIPv6Subnet = config.Subnet
				enableIPv6 = true
				if err := assignAddress(config.Gateway, &requestedIPv4Gateway, &requestedIPv6Gateway); err != nil {
					return api.NetworkResource{}, err
				}
				requestedIPv6Range = config.IPRange
				requestedIPv6Auxiliary = cloneStringMap(config.AuxiliaryAddresses)
			}
		}
	}
	if !enableIPv4 && requestedIPv4Subnet != "" {
		return api.NetworkResource{}, errors.New("IPv4 IPAM is configured while IPv4 is disabled")
	}
	if requestedIPv6Subnet != "" {
		enableIPv6 = true
	}
	var subnet *net.IPNet
	var gateway string
	var err error
	if enableIPv4 {
		subnet, gateway, err = m.allocateSubnetLocked(requestedIPv4Subnet, requestedIPv4Gateway)
		if err != nil {
			return api.NetworkResource{}, err
		}
	}
	var ipv6Subnet *net.IPNet
	var ipv6Gateway string
	if enableIPv6 {
		ipv6Subnet, ipv6Gateway, err = m.allocateIPv6SubnetLocked(requestedIPv6Subnet, requestedIPv6Gateway)
		if err != nil {
			return api.NetworkResource{}, err
		}
	}
	var ipRange *net.IPNet
	if requestedIPv4Range != "" {
		ipRange, err = validateIPRange(requestedIPv4Range, subnet, gateway, false)
		if err != nil {
			return api.NetworkResource{}, err
		}
	}
	var ipv6IPRange *net.IPNet
	if requestedIPv6Range != "" {
		ipv6IPRange, err = validateIPRange(requestedIPv6Range, ipv6Subnet, ipv6Gateway, true)
		if err != nil {
			return api.NetworkResource{}, err
		}
	}
	if err := validateAuxiliaryAddresses(requestedIPv4Auxiliary, subnet, gateway, false); err != nil {
		return api.NetworkResource{}, err
	}
	if err := validateAuxiliaryAddresses(requestedIPv6Auxiliary, ipv6Subnet, ipv6Gateway, true); err != nil {
		return api.NetworkResource{}, err
	}
	for name, address := range requestedIPv4Auxiliary {
		requestedIPv4Auxiliary[name] = net.ParseIP(address).To4().String()
	}
	for name, address := range requestedIPv6Auxiliary {
		requestedIPv6Auxiliary[name] = net.ParseIP(address).To16().String()
	}
	idSubnet := ""
	if subnet != nil {
		idSubnet = subnet.String()
	}
	if ipv6Subnet != nil {
		if idSubnet != "" {
			idSubnet += "\x00"
		}
		idSubnet += ipv6Subnet.String()
	}
	id := networkID(request.Name, idSubnet)
	bridge := networkBridgeName(id)
	if err := m.createBridge(bridge, subnet, gateway, ipv6Subnet, ipv6Gateway, request.Internal); err != nil {
		return api.NetworkResource{}, err
	}
	driver := valueOrNetwork(request.Driver, "bridge")
	if driver == "default" {
		driver = "bridge"
	}
	scope := valueOrNetwork(request.Scope, "local")
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
		ipv6Subnet: ipv6Subnet, ipv6Gateway: ipv6Gateway,
		driver: driver, scope: scope, createdAt: time.Now().UTC(), labels: cloneStringMap(request.Labels),
		options: cloneStringMap(request.Options), internal: request.Internal, enableIPv4: enableIPv4,
		enableIPv6: enableIPv6, attachable: attachable, ingress: ingress, ipamDriver: ipamDriver,
		ipRange: ipRange, ipv6IPRange: ipv6IPRange, auxiliary: requestedIPv4Auxiliary,
		ipv6Auxiliary: requestedIPv6Auxiliary,
		containers:    make(map[string]*networkEndpoint),
	}
	m.networks[id] = network
	if err := m.persistNetworksLocked(); err != nil {
		delete(m.networks, id)
		_ = m.runner.Run("ip", "link", "delete", bridge)
		return api.NetworkResource{}, err
	}
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
	if err := m.persistNetworksLocked(); err != nil {
		return err
	}
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
	if len(result.NetworksDeleted) > 0 {
		if err := m.persistNetworksLocked(); err != nil {
			result.Errors["state"] = err.Error()
		}
	}
	return result
}

func (m *NetworkManager) ConnectNetwork(request api.NetworkConnectRequest) (api.NetworkResource, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.connectNetworkLocked(request)
}

func (m *NetworkManager) connectNetworkLocked(request api.NetworkConnectRequest) (api.NetworkResource, error) {
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
	ipv6Address := ""
	if network.enableIPv6 {
		ipv6Address, err = m.allocateIPv6AddressLocked(network, request.IPv6Address)
		if err != nil {
			return api.NetworkResource{}, err
		}
	} else if request.IPv6Address != "" {
		return api.NetworkResource{}, fmt.Errorf("network %s does not have IPv6 enabled", network.name)
	}
	interfaceName := fmt.Sprintf("eth%d", len(container.endpoints))
	endpointID := endpointName(network.id, request.ContainerID)
	hostVeth := "vh" + endpointID[:10]
	containerVeth := "vc" + endpointID[:10]
	ipv4Prefix := 0
	if network.subnet != nil {
		ipv4Prefix, _ = network.subnet.Mask.Size()
	}
	ipv6Prefix := 0
	if network.ipv6Subnet != nil {
		ipv6Prefix, _ = network.ipv6Subnet.Mask.Size()
	}
	ipv4Gateway, ipv6Gateway := "", ""
	if len(container.endpoints) == 0 {
		ipv4Gateway, ipv6Gateway = network.gateway, network.ipv6Gateway
	}
	if err := m.attachNamespace(
		container.name, network.bridge, hostVeth, containerVeth,
		address, ipv4Prefix, ipv6Address, ipv6Prefix, ipv4Gateway, ipv6Gateway, interfaceName,
	); err != nil {
		return api.NetworkResource{}, err
	}
	if len(container.endpoints) == 0 {
		// The first endpoint is the container's primary address. Port
		// publication and the guest forwarding path use this address.
		container.address = address
	}
	aliases := normalizeAliases(request.Aliases, container)
	endpoint := &networkEndpoint{
		networkID: network.id, interfaceName: interfaceName, endpointID: endpointID,
		address: address, ipv6Address: ipv6Address, aliases: aliases,
	}
	container.endpoints[network.id] = endpoint
	network.containers[request.ContainerID] = endpoint
	return m.networkResourceLocked(network), nil
}

// ConfigureContainerNetwork replaces the default bridge endpoint with the
// requested Docker network during container creation. The runtime still needs
// a private namespace, but a container created with --network <name> must not
// retain an implicit bridge endpoint.
func (m *NetworkManager) ConfigureContainerNetwork(containerID, networkReference, containerName string) error {
	return m.ConfigureContainerNetworkWithAddresses(
		containerID, networkReference, containerName, "", "", nil,
	)
}

// ConfigureContainerNetworkWithAddresses replaces the implicit bridge
// endpoint with the requested Docker network and its endpoint IPAM settings.
func (m *NetworkManager) ConfigureContainerNetworkWithAddresses(
	containerID, networkReference, containerName, ipv4Address, ipv6Address string,
	aliases []string,
) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.configureContainerNetworkLocked(
		containerID, networkReference, containerName, ipv4Address, ipv6Address, aliases,
	)
}

// RemoveDefaultNetwork removes the implicit bridge endpoint without exposing
// the operation through the Docker network API. It is used when a container
// created with a custom network has been explicitly disconnected from that
// network and is started again without any remaining endpoint.
func (m *NetworkManager) RemoveDefaultNetwork(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.removeDefaultNetworkLocked(id)
}

func (m *NetworkManager) removeDefaultNetworkLocked(id string) error {
	container := m.containers[id]
	if container == nil {
		return nil
	}
	defaultNetwork := m.networks[defaultNetworkID]
	if defaultNetwork == nil {
		return nil
	}
	endpoint := defaultNetwork.containers[id]
	if endpoint == nil {
		return nil
	}
	if err := m.detachNamespace(container.name, endpoint.interfaceName); err != nil {
		return fmt.Errorf("remove default network from container %s: %w", id, err)
	}
	delete(defaultNetwork.containers, id)
	delete(container.endpoints, defaultNetworkID)
	m.reselectContainerAddressLocked(container)
	return nil
}

func (m *NetworkManager) reselectContainerAddressLocked(container *containerNetwork) {
	container.address = ""
	for _, endpoint := range container.endpoints {
		if endpoint.address != "" {
			container.address = endpoint.address
			return
		}
	}
}

func (m *NetworkManager) configureContainerNetworkLocked(
	containerID, networkReference, containerName, ipv4Address, ipv6Address string,
	aliases []string,
) error {
	network := m.resolveNetworkLocked(networkReference)
	if network == nil {
		return fmt.Errorf("network %s not found", networkReference)
	}
	if network.id == defaultNetworkID {
		return nil
	}
	container := m.containers[containerID]
	if container == nil {
		return fmt.Errorf("container %s not found", containerID)
	}
	if containerName != "" {
		container.identity = containerName
	}
	if _, exists := network.containers[containerID]; exists {
		return nil
	}
	if m.networks[defaultNetworkID] == nil {
		return errors.New("default bridge network is not initialized")
	}
	if err := m.removeDefaultNetworkLocked(containerID); err != nil {
		return err
	}
	if _, err := m.connectNetworkLocked(api.NetworkConnectRequest{
		NetworkID: network.id, ContainerID: containerID, Aliases: append([]string{containerName}, aliases...),
		IPv4Address: ipv4Address, IPv6Address: ipv6Address,
	}); err != nil {
		return fmt.Errorf("connect container %s to network %s: %w", containerID, network.name, err)
	}
	return nil
}

// RestoreContainer rebuilds the network namespace and all persisted Docker
// network attachments after the guest VM restarts. Containerd preserves the
// container metadata, but the namespace and veth devices belong to the VM and
// must be recreated before a stopped container is inspected or started.
func (m *NetworkManager) RestoreContainer(
	id, name, hostname, networkMode string, attachments []api.ContainerNetworkAttachment,
) (bool, error) {
	if !usesPrivateNetworkNamespace(networkMode) {
		return false, nil
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.initialize(); err != nil {
		return false, err
	}
	created := false
	if _, exists := m.containers[id]; !exists {
		if _, err := m.createLocked(id, "", "", name, hostname); err != nil {
			return false, err
		}
		created = true
	}
	m.setContainerIdentityLocked(id, name, hostname)
	if isCustomNetworkMode(networkMode) {
		network := m.resolveNetworkLocked(networkMode)
		if network == nil {
			return false, fmt.Errorf("network %s not found", networkMode)
		}
		var primary *api.ContainerNetworkAttachment
		for _, attachment := range attachments {
			if attachment.NetworkID == network.id {
				attachmentCopy := attachment
				primary = &attachmentCopy
				break
			}
		}
		if primary != nil {
			if err := m.configureContainerNetworkLocked(
				id, networkMode, name, primary.IPv4Address, primary.IPv6Address, primary.Aliases,
			); err != nil {
				return false, err
			}
		} else if err := m.removeDefaultNetworkLocked(id); err != nil {
			return false, err
		}
	}
	for _, attachment := range attachments {
		network := m.resolveNetworkLocked(attachment.NetworkID)
		if network == nil {
			return false, fmt.Errorf("network %s not found", attachment.NetworkID)
		}
		if _, exists := network.containers[id]; exists {
			continue
		}
		if _, err := m.connectNetworkLocked(api.NetworkConnectRequest{
			NetworkID: network.id, ContainerID: id,
			Aliases: attachment.Aliases, IPv4Address: attachment.IPv4Address,
			IPv6Address: attachment.IPv6Address,
		}); err != nil {
			return false, fmt.Errorf("restore container %s on network %s: %w", id, network.name, err)
		}
	}
	return created, nil
}

func (m *NetworkManager) DisconnectNetwork(request api.NetworkDisconnectRequest) (api.NetworkResource, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.disconnectNetworkLocked(request)
}

func (m *NetworkManager) disconnectNetworkLocked(request api.NetworkDisconnectRequest) (api.NetworkResource, error) {
	network := m.resolveNetworkLocked(request.NetworkID)
	if network == nil {
		return api.NetworkResource{}, fmt.Errorf("network %s not found", request.NetworkID)
	}
	container := m.containers[request.ContainerID]
	if container == nil {
		return api.NetworkResource{}, fmt.Errorf("container %s not found", request.ContainerID)
	}
	if network.id == defaultNetworkID || network.name == "bridge" {
		return api.NetworkResource{}, errors.New("default bridge network cannot be disconnected")
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
	m.reselectContainerAddressLocked(container)
	return m.networkResourceLocked(network), nil
}

func (m *NetworkManager) SetContainerIdentity(id, name, hostname string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.setContainerIdentityLocked(id, name, hostname)
}

func (m *NetworkManager) setContainerIdentityLocked(id, name, hostname string) {
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
		if network.ipv6Gateway != "" {
			nameservers = append(nameservers, network.ipv6Gateway)
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
			addresses := []string{endpoint.address, endpoint.ipv6Address}
			for _, address := range addresses {
				if address == "" {
					continue
				}
				entries = append(entries, hostEntry{address: address, name: name})
				if other.hostname != "" && other.hostname != name {
					entries = append(entries, hostEntry{address: address, name: other.hostname})
				}
				for _, alias := range endpoint.aliases {
					entries = append(entries, hostEntry{address: address, name: alias})
				}
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
			IPv6Gateway: network.ipv6Gateway,
			Aliases:     append([]string(nil), endpoint.aliases...),
		}
	}
	configs := make([]api.NetworkIPAMConfig, 0, 2)
	if network.subnet != nil {
		configs = append(configs, api.NetworkIPAMConfig{
			Subnet: network.subnet.String(), IPRange: ipRangeString(network.ipRange),
			Gateway: network.gateway, AuxiliaryAddresses: cloneStringMap(network.auxiliary),
		})
	}
	if network.ipv6Subnet != nil {
		configs = append(configs, api.NetworkIPAMConfig{
			Subnet: network.ipv6Subnet.String(), IPRange: ipRangeString(network.ipv6IPRange),
			Gateway: network.ipv6Gateway, AuxiliaryAddresses: cloneStringMap(network.ipv6Auxiliary),
		})
	}
	subnet, gateway := "", ""
	if network.subnet != nil {
		subnet, gateway = network.subnet.String(), network.gateway
	} else if network.ipv6Subnet != nil {
		subnet, gateway = network.ipv6Subnet.String(), network.ipv6Gateway
	}
	return api.NetworkResource{
		ID: network.id, Name: network.name, CreatedAt: network.createdAt, Scope: valueOrNetwork(network.scope, "local"),
		Driver: network.driver, EnableIPv4: network.enableIPv4, EnableIPv6: network.enableIPv6,
		Internal: network.internal, Attachable: network.attachable, Ingress: network.ingress,
		IPAM: api.NetworkIPAM{
			Driver: valueOrNetwork(network.ipamDriver, "default"),
			Config: configs,
		},
		Subnet: subnet, Gateway: gateway,
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
	if candidate == nil {
		return false
	}
	isIPv4 := candidate.IP.To4() != nil
	for _, network := range m.networks {
		existing := network.ipv6Subnet
		if isIPv4 {
			existing = network.subnet
		}
		if existing != nil && (existing.Contains(candidate.IP) || candidate.Contains(existing.IP)) {
			return true
		}
	}
	return false
}

func (m *NetworkManager) allocateAddressLocked(network *managedNetwork, requested string) (string, error) {
	pool := network.subnet
	if pool == nil {
		return "", fmt.Errorf("network %s does not have IPv4 enabled", network.name)
	}
	if network.ipRange != nil {
		pool = network.ipRange
	}
	if requested != "" {
		address := net.ParseIP(requested).To4()
		if address == nil || !pool.Contains(address) || address.String() == network.gateway ||
			address.Equal(pool.IP) || address.Equal(lastIP(pool)) {
			return "", fmt.Errorf("IPv4 address %q is outside network %s", requested, network.name)
		}
		if auxiliaryAddressExists(network.auxiliary, address.String()) {
			return "", fmt.Errorf("IPv4 address %s is reserved by network %s", requested, network.name)
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
			if auxiliaryAddressExists(network.auxiliary, candidate) || candidate == pool.IP.String() || candidate == lastIP(pool).String() {
				continue
			}
			return candidate, nil
		}
	}
	return "", fmt.Errorf("network %s address space is exhausted", network.name)
}

func (m *NetworkManager) allocateIPv6SubnetLocked(requested, requestedGateway string) (*net.IPNet, string, error) {
	var subnet *net.IPNet
	var err error
	if requested != "" {
		_, subnet, err = net.ParseCIDR(requested)
		if err != nil || subnet.IP.To4() != nil {
			return nil, "", fmt.Errorf("invalid IPv6 subnet %q", requested)
		}
	} else {
		for attempts := 0; attempts < 0xffff; attempts++ {
			candidate := fmt.Sprintf("fd00:%x::/64", m.nextIPv6Subnet)
			m.nextIPv6Subnet++
			_, candidateSubnet, parseErr := net.ParseCIDR(candidate)
			if parseErr == nil && !m.subnetOverlapsLocked(candidateSubnet) {
				subnet = candidateSubnet
				break
			}
		}
		if subnet == nil {
			return nil, "", errors.New("IPv6 network address space is exhausted")
		}
	}
	if m.subnetOverlapsLocked(subnet) {
		return nil, "", fmt.Errorf("network subnet %s overlaps an existing network", subnet.String())
	}
	gateway := requestedGateway
	if gateway == "" {
		gatewayIP := append(net.IP(nil), subnet.IP.To16()...)
		gatewayIP[15]++
		gateway = gatewayIP.String()
	}
	parsedGateway := net.ParseIP(gateway)
	if parsedGateway == nil || parsedGateway.To4() != nil || !subnet.Contains(parsedGateway) || parsedGateway.Equal(subnet.IP) {
		return nil, "", fmt.Errorf("gateway %q is outside IPv6 subnet %s", gateway, subnet.String())
	}
	return subnet, parsedGateway.To16().String(), nil
}

func (m *NetworkManager) allocateIPv6AddressLocked(network *managedNetwork, requested string) (string, error) {
	pool := network.ipv6Subnet
	if pool == nil {
		return "", fmt.Errorf("network %s does not have IPv6 enabled", network.name)
	}
	if network.ipv6IPRange != nil {
		pool = network.ipv6IPRange
	}
	if requested != "" {
		address := net.ParseIP(requested)
		if address == nil || address.To4() != nil || !pool.Contains(address) || address.Equal(net.ParseIP(network.ipv6Gateway)) ||
			address.Equal(pool.IP) || address.Equal(lastIP(pool)) {
			return "", fmt.Errorf("IPv6 address %q is outside network %s", requested, network.name)
		}
		canonical := address.To16().String()
		if auxiliaryAddressExists(network.ipv6Auxiliary, canonical) {
			return "", fmt.Errorf("IPv6 address %s is reserved by network %s", requested, network.name)
		}
		for _, endpoint := range network.containers {
			if endpoint.ipv6Address == canonical {
				return "", fmt.Errorf("IPv6 address %s is already in use", requested)
			}
		}
		return canonical, nil
	}
	base := new(big.Int).SetBytes(pool.IP.To16())
	last := new(big.Int).SetBytes(lastIP(pool).To16())
	first := new(big.Int).Add(base, big.NewInt(1))
	if gateway := new(big.Int).SetBytes(net.ParseIP(network.ipv6Gateway).To16()); gateway.Cmp(first) >= 0 {
		first = new(big.Int).Add(gateway, big.NewInt(1))
	}
	candidate := new(big.Int).Set(first)
	for attempts := 0; candidate.Cmp(last) < 0 && attempts < 1<<20; attempts++ {
		canonical := bigToIPv6(candidate).String()
		if !auxiliaryAddressExists(network.ipv6Auxiliary, canonical) {
			used := false
			for _, endpoint := range network.containers {
				if endpoint.ipv6Address == canonical {
					used = true
					break
				}
			}
			if !used {
				return canonical, nil
			}
		}
		candidate.Add(candidate, big.NewInt(1))
	}
	return "", fmt.Errorf("network %s IPv6 address space is exhausted", network.name)
}

func validateIPRange(value string, subnet *net.IPNet, gateway string, ipv6 bool) (*net.IPNet, error) {
	if subnet == nil {
		return nil, fmt.Errorf("IP range %q has no matching network subnet", value)
	}
	_, parsed, err := net.ParseCIDR(value)
	if err != nil || (parsed.IP.To4() == nil) == !ipv6 || !subnet.Contains(parsed.IP) || !subnet.Contains(lastIP(parsed)) {
		return nil, fmt.Errorf("invalid IP range %q for subnet %s", value, subnet)
	}
	if gateway != "" && parsed.Contains(net.ParseIP(gateway)) {
		return nil, fmt.Errorf("IP range %q contains the network gateway %s", value, gateway)
	}
	return parsed, nil
}

func validateAuxiliaryAddresses(values map[string]string, subnet *net.IPNet, gateway string, ipv6 bool) error {
	if subnet == nil && len(values) != 0 {
		return errors.New("auxiliary addresses have no matching network subnet")
	}
	for name, address := range values {
		parsed := net.ParseIP(address)
		if parsed == nil || (parsed.To4() == nil) != ipv6 || !subnet.Contains(parsed) || parsed.String() == gateway || parsed.Equal(subnet.IP) || parsed.Equal(lastIP(subnet)) {
			return fmt.Errorf("invalid auxiliary address %q for subnet %s", address, subnet)
		}
		if name == "" {
			return errors.New("auxiliary address name is required")
		}
	}
	return nil
}

func auxiliaryAddressExists(values map[string]string, address string) bool {
	for _, value := range values {
		parsed := net.ParseIP(value)
		if parsed != nil && parsed.String() == address {
			return true
		}
	}
	return false
}

func (m *NetworkManager) createBridge(
	bridge string, subnet *net.IPNet, gateway string,
	ipv6Subnet *net.IPNet, ipv6Gateway string, internal bool,
) error {
	commands := [][]string{{"ip", "link", "add", bridge, "type", "bridge"}}
	if subnet != nil {
		prefix, _ := subnet.Mask.Size()
		commands = append(commands, []string{
			"ip", "addr", "add", fmt.Sprintf("%s/%d", gateway, prefix), "dev", bridge,
		})
	}
	if ipv6Subnet != nil {
		prefix, _ := ipv6Subnet.Mask.Size()
		commands = append(commands, []string{
			"ip", "-6", "addr", "add", fmt.Sprintf("%s/%d", ipv6Gateway, prefix), "dev", bridge, "nodad",
		})
	}
	commands = append(commands, []string{"ip", "link", "set", bridge, "up"})
	if !internal && subnet != nil {
		commands = append(commands,
			[]string{"iptables", "-t", "nat", "-A", "POSTROUTING", "-s", subnet.String(), "!", "-o", bridge, "-j", "MASQUERADE"},
			[]string{"iptables", "-A", "FORWARD", "-i", bridge, "-j", "ACCEPT"},
			[]string{"iptables", "-A", "FORWARD", "-o", bridge, "-m", "conntrack", "--ctstate", "RELATED,ESTABLISHED", "-j", "ACCEPT"},
		)
	}
	if ipv6Subnet != nil {
		commands = append(commands, []string{"sysctl", "-w", "net.ipv6.conf.all.forwarding=1"})
	}
	for _, command := range commands {
		if err := m.runner.Run(command[0], command[1:]...); err != nil {
			_ = m.runner.Run("ip", "link", "delete", bridge)
			return err
		}
	}
	return nil
}

func (m *NetworkManager) attachNamespace(
	namespace, bridge, hostVeth, containerVeth string,
	ipv4Address string, ipv4Prefix int,
	ipv6Address string, ipv6Prefix int,
	ipv4Gateway string, ipv6Gateway string,
	interfaceName string,
) error {
	if operations, ok := m.namespaces.(networkAttachmentOperations); ok {
		return operations.Attach(
			namespace, bridge, hostVeth, containerVeth,
			ipv4Address, ipv4Prefix, ipv6Address, ipv6Prefix,
			ipv4Gateway, ipv6Gateway, interfaceName,
		)
	}
	args := []string{"attach", namespace, bridge, hostVeth, containerVeth}
	if ipv4Address != "" {
		args = append(args, "addr", fmt.Sprintf("%s/%d", ipv4Address, ipv4Prefix))
	}
	if ipv6Address != "" {
		args = append(args, "addr6", fmt.Sprintf("%s/%d", ipv6Address, ipv6Prefix))
	}
	if ipv4Gateway != "" {
		args = append(args, "route4", "default", "via", ipv4Gateway)
	}
	if ipv6Gateway != "" {
		args = append(args, "route6", "default", "via", ipv6Gateway)
	}
	args = append(args, "dev", interfaceName)
	return m.runner.Run("netlink", args...)
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
	if network == nil {
		return nil
	}
	last := append(net.IP(nil), network.IP.To16()...)
	mask := network.Mask
	if network.IP.To4() != nil {
		last = append(net.IP(nil), network.IP.To4()...)
		mask = mask[len(mask)-net.IPv4len:]
	}
	for index := range last {
		last[index] |= ^mask[index]
	}
	return last
}

func bigToIPv6(value *big.Int) net.IP {
	bytes := value.Bytes()
	address := make([]byte, net.IPv6len)
	copy(address[len(address)-len(bytes):], bytes)
	return net.IP(address)
}

func legacyIPv6Subnet(id string) *net.IPNet {
	digest := sha256.Sum256([]byte("glassdock-ipv6\x00" + id))
	selector := uint16(digest[0])<<8 | uint16(digest[1])
	if selector == 0 {
		selector = 1
	}
	_, subnet, _ := net.ParseCIDR(fmt.Sprintf("fd00:%x::/64", selector))
	return subnet
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
	if err := m.loadPersistedNetworksLocked(); err != nil {
		m.initialized = false
		return err
	}
	return nil
}

func (m *NetworkManager) loadPersistedNetworksLocked() error {
	if m.statePath == "" {
		return nil
	}
	data, err := os.ReadFile(m.statePath)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("read network state: %w", err)
	}
	var state persistedNetworkState
	if err := json.Unmarshal(data, &state); err != nil {
		return fmt.Errorf("decode network state: %w", err)
	}
	loadedBridges := make([]string, 0, len(state.Networks))
	for _, stored := range state.Networks {
		if stored.ID == "" || stored.Name == "" || stored.ID == defaultNetworkID {
			return errors.New("network state contains an invalid network identity")
		}
		if m.resolveNetworkLocked(stored.ID) != nil || m.networkByNameLocked(stored.Name) != nil {
			return fmt.Errorf("network state contains a duplicate network %q", stored.Name)
		}
		enableIPv4 := stored.EnableIPv4 || stored.Subnet != ""
		enableIPv6 := stored.EnableIPv6 || stored.IPv6Subnet != ""
		var subnet *net.IPNet
		if stored.Subnet != "" {
			_, parsed, parseErr := net.ParseCIDR(stored.Subnet)
			if parseErr != nil || parsed.IP.To4() == nil {
				return fmt.Errorf("network %q has an invalid subnet %q", stored.Name, stored.Subnet)
			}
			subnet = parsed
		}
		if enableIPv4 && subnet == nil {
			return fmt.Errorf("network %q has no IPv4 subnet", stored.Name)
		}
		if subnet != nil && m.subnetOverlapsLocked(subnet) {
			return fmt.Errorf("network %q overlaps an existing network", stored.Name)
		}
		gateway := ""
		if subnet != nil {
			parsedGateway := net.ParseIP(stored.Gateway).To4()
			if parsedGateway == nil || !subnet.Contains(parsedGateway) || parsedGateway.Equal(subnet.IP) {
				return fmt.Errorf("network %q has an invalid gateway %q", stored.Name, stored.Gateway)
			}
			gateway = parsedGateway.String()
		}
		var ipv6Subnet *net.IPNet
		if stored.IPv6Subnet != "" {
			_, parsed, parseErr := net.ParseCIDR(stored.IPv6Subnet)
			if parseErr != nil || parsed.IP.To4() != nil {
				return fmt.Errorf("network %q has an invalid IPv6 subnet %q", stored.Name, stored.IPv6Subnet)
			}
			ipv6Subnet = parsed
		} else if enableIPv6 {
			ipv6Subnet = legacyIPv6Subnet(stored.ID)
		}
		if enableIPv6 && ipv6Subnet == nil {
			return fmt.Errorf("network %q has no IPv6 subnet", stored.Name)
		}
		if ipv6Subnet != nil && m.subnetOverlapsLocked(ipv6Subnet) {
			return fmt.Errorf("network %q overlaps an existing IPv6 network", stored.Name)
		}
		ipv6Gateway := ""
		if ipv6Subnet != nil {
			ipv6Gateway = stored.IPv6Gateway
			if ipv6Gateway == "" {
				gatewayIP := append(net.IP(nil), ipv6Subnet.IP.To16()...)
				gatewayIP[15]++
				ipv6Gateway = gatewayIP.String()
			}
			parsedGateway := net.ParseIP(ipv6Gateway)
			if parsedGateway == nil || parsedGateway.To4() != nil || !ipv6Subnet.Contains(parsedGateway) || parsedGateway.Equal(ipv6Subnet.IP) {
				return fmt.Errorf("network %q has an invalid IPv6 gateway %q", stored.Name, ipv6Gateway)
			}
			ipv6Gateway = parsedGateway.To16().String()
		}
		if subnet == nil && ipv6Subnet == nil {
			return fmt.Errorf("network %q has no address pool", stored.Name)
		}
		var ipRange *net.IPNet
		if stored.IPRange != "" {
			ipRange, err = validateIPRange(stored.IPRange, subnet, gateway, false)
			if err != nil {
				return fmt.Errorf("network %q: %w", stored.Name, err)
			}
		}
		var ipv6IPRange *net.IPNet
		if stored.IPv6IPRange != "" {
			ipv6IPRange, err = validateIPRange(stored.IPv6IPRange, ipv6Subnet, ipv6Gateway, true)
			if err != nil {
				return fmt.Errorf("network %q: %w", stored.Name, err)
			}
		}
		if err := validateAuxiliaryAddresses(stored.Auxiliary, subnet, gateway, false); err != nil {
			return fmt.Errorf("network %q: %w", stored.Name, err)
		}
		if err := validateAuxiliaryAddresses(stored.IPv6Auxiliary, ipv6Subnet, ipv6Gateway, true); err != nil {
			return fmt.Errorf("network %q: %w", stored.Name, err)
		}
		bridge := networkBridgeName(stored.ID)
		if err := m.createBridge(bridge, subnet, gateway, ipv6Subnet, ipv6Gateway, stored.Internal); err != nil {
			for _, loaded := range loadedBridges {
				_ = m.runner.Run("ip", "link", "delete", loaded)
			}
			return fmt.Errorf("restore network %q: %w", stored.Name, err)
		}
		loadedBridges = append(loadedBridges, bridge)
		m.networks[stored.ID] = &managedNetwork{
			id: stored.ID, name: stored.Name, bridge: bridge, subnet: subnet, gateway: gateway,
			ipv6Subnet: ipv6Subnet, ipv6Gateway: ipv6Gateway,
			driver: valueOrNetwork(stored.Driver, "bridge"), scope: valueOrNetwork(stored.Scope, "local"),
			createdAt: stored.CreatedAt, labels: cloneStringMap(stored.Labels), options: cloneStringMap(stored.Options),
			internal: stored.Internal, enableIPv4: enableIPv4, enableIPv6: enableIPv6,
			attachable: stored.Attachable, ingress: stored.Ingress,
			ipamDriver: valueOrNetwork(stored.IPAMDriver, "default"), ipRange: ipRange,
			ipv6IPRange: ipv6IPRange, auxiliary: cloneStringMap(stored.Auxiliary),
			ipv6Auxiliary: cloneStringMap(stored.IPv6Auxiliary), containers: make(map[string]*networkEndpoint),
		}
	}
	return nil
}

func (m *NetworkManager) persistNetworksLocked() error {
	if m.statePath == "" {
		return nil
	}
	ids := make([]string, 0, len(m.networks))
	for id, network := range m.networks {
		if id != defaultNetworkID && network != nil {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	state := persistedNetworkState{Networks: make([]persistedNetwork, 0, len(ids))}
	for _, id := range ids {
		network := m.networks[id]
		state.Networks = append(state.Networks, persistedNetwork{
			ID: network.id, Name: network.name, Subnet: ipRangeString(network.subnet), Gateway: network.gateway,
			IPv6Subnet: ipRangeString(network.ipv6Subnet), IPv6Gateway: network.ipv6Gateway,
			Driver: network.driver, Scope: network.scope, CreatedAt: network.createdAt,
			Labels: cloneStringMap(network.labels), Options: cloneStringMap(network.options),
			Internal: network.internal, EnableIPv4: network.enableIPv4, EnableIPv6: network.enableIPv6,
			Attachable: network.attachable, Ingress: network.ingress, IPAMDriver: network.ipamDriver,
			IPRange: ipRangeString(network.ipRange), IPv6IPRange: ipRangeString(network.ipv6IPRange),
			Auxiliary: cloneStringMap(network.auxiliary), IPv6Auxiliary: cloneStringMap(network.ipv6Auxiliary),
		})
	}
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return fmt.Errorf("encode network state: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(m.statePath), 0o755); err != nil {
		return fmt.Errorf("create network state directory: %w", err)
	}
	temp, err := os.CreateTemp(filepath.Dir(m.statePath), ".networks-*.tmp")
	if err != nil {
		return fmt.Errorf("create network state file: %w", err)
	}
	tempName := temp.Name()
	defer os.Remove(tempName)
	if err := temp.Chmod(0o600); err != nil {
		_ = temp.Close()
		return fmt.Errorf("set network state permissions: %w", err)
	}
	if _, err := temp.Write(data); err != nil {
		_ = temp.Close()
		return fmt.Errorf("write network state: %w", err)
	}
	if err := temp.Sync(); err != nil {
		_ = temp.Close()
		return fmt.Errorf("sync network state: %w", err)
	}
	if err := temp.Close(); err != nil {
		return fmt.Errorf("close network state: %w", err)
	}
	if err := os.Rename(tempName, m.statePath); err != nil {
		return fmt.Errorf("replace network state: %w", err)
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
