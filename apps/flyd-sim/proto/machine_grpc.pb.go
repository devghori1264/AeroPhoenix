package proto

import (
	context "context"

	grpc "google.golang.org/grpc"
	codes "google.golang.org/grpc/codes"
	status "google.golang.org/grpc/status"
)

const _ = grpc.SupportPackageIsVersion9

const (
	MachineService_Ping_FullMethodName                    = "/aerophoenix.machine.MachineService/Ping"
	MachineService_CreateMachine_FullMethodName           = "/aerophoenix.machine.MachineService/CreateMachine"
	MachineService_GetMachine_FullMethodName              = "/aerophoenix.machine.MachineService/GetMachine"
	MachineService_StartMachine_FullMethodName            = "/aerophoenix.machine.MachineService/StartMachine"
	MachineService_StopMachine_FullMethodName             = "/aerophoenix.machine.MachineService/StopMachine"
	MachineService_MigrateMachine_FullMethodName          = "/aerophoenix.machine.MachineService/MigrateMachine"
	MachineService_GetMigrationStatus_FullMethodName      = "/aerophoenix.machine.MachineService/GetMigrationStatus"
	MachineService_StreamMigrationProgress_FullMethodName = "/aerophoenix.machine.MachineService/StreamMigrationProgress"
)

type MachineServiceClient interface {
	Ping(ctx context.Context, in *PingRequest, opts ...grpc.CallOption) (*PingResponse, error)
	CreateMachine(ctx context.Context, in *CreateRequest, opts ...grpc.CallOption) (*CreateResponse, error)
	GetMachine(ctx context.Context, in *GetRequest, opts ...grpc.CallOption) (*GetResponse, error)
	StartMachine(ctx context.Context, in *ActionRequest, opts ...grpc.CallOption) (*ActionResponse, error)
	StopMachine(ctx context.Context, in *ActionRequest, opts ...grpc.CallOption) (*ActionResponse, error)
	MigrateMachine(ctx context.Context, in *MigrateRequest, opts ...grpc.CallOption) (*MigrateResponse, error)
	GetMigrationStatus(ctx context.Context, in *MigrationStatusRequest, opts ...grpc.CallOption) (*MigrationStatusResponse, error)
	StreamMigrationProgress(ctx context.Context, in *MigrationStatusRequest, opts ...grpc.CallOption) (grpc.ServerStreamingClient[MigrationProgressEvent], error)
}

type machineServiceClient struct {
	cc grpc.ClientConnInterface
}

func NewMachineServiceClient(cc grpc.ClientConnInterface) MachineServiceClient {
	return &machineServiceClient{cc}
}

func (c *machineServiceClient) Ping(ctx context.Context, in *PingRequest, opts ...grpc.CallOption) (*PingResponse, error) {
	cOpts := append([]grpc.CallOption{grpc.StaticMethod()}, opts...)
	out := new(PingResponse)
	err := c.cc.Invoke(ctx, MachineService_Ping_FullMethodName, in, out, cOpts...)
	if err != nil {
		return nil, err
	}
	return out, nil
}

func (c *machineServiceClient) CreateMachine(ctx context.Context, in *CreateRequest, opts ...grpc.CallOption) (*CreateResponse, error) {
	cOpts := append([]grpc.CallOption{grpc.StaticMethod()}, opts...)
	out := new(CreateResponse)
	err := c.cc.Invoke(ctx, MachineService_CreateMachine_FullMethodName, in, out, cOpts...)
	if err != nil {
		return nil, err
	}
	return out, nil
}

func (c *machineServiceClient) GetMachine(ctx context.Context, in *GetRequest, opts ...grpc.CallOption) (*GetResponse, error) {
	cOpts := append([]grpc.CallOption{grpc.StaticMethod()}, opts...)
	out := new(GetResponse)
	err := c.cc.Invoke(ctx, MachineService_GetMachine_FullMethodName, in, out, cOpts...)
	if err != nil {
		return nil, err
	}
	return out, nil
}

func (c *machineServiceClient) StartMachine(ctx context.Context, in *ActionRequest, opts ...grpc.CallOption) (*ActionResponse, error) {
	cOpts := append([]grpc.CallOption{grpc.StaticMethod()}, opts...)
	out := new(ActionResponse)
	err := c.cc.Invoke(ctx, MachineService_StartMachine_FullMethodName, in, out, cOpts...)
	if err != nil {
		return nil, err
	}
	return out, nil
}

func (c *machineServiceClient) StopMachine(ctx context.Context, in *ActionRequest, opts ...grpc.CallOption) (*ActionResponse, error) {
	cOpts := append([]grpc.CallOption{grpc.StaticMethod()}, opts...)
	out := new(ActionResponse)
	err := c.cc.Invoke(ctx, MachineService_StopMachine_FullMethodName, in, out, cOpts...)
	if err != nil {
		return nil, err
	}
	return out, nil
}

func (c *machineServiceClient) MigrateMachine(ctx context.Context, in *MigrateRequest, opts ...grpc.CallOption) (*MigrateResponse, error) {
	cOpts := append([]grpc.CallOption{grpc.StaticMethod()}, opts...)
	out := new(MigrateResponse)
	err := c.cc.Invoke(ctx, MachineService_MigrateMachine_FullMethodName, in, out, cOpts...)
	if err != nil {
		return nil, err
	}
	return out, nil
}

func (c *machineServiceClient) GetMigrationStatus(ctx context.Context, in *MigrationStatusRequest, opts ...grpc.CallOption) (*MigrationStatusResponse, error) {
	cOpts := append([]grpc.CallOption{grpc.StaticMethod()}, opts...)
	out := new(MigrationStatusResponse)
	err := c.cc.Invoke(ctx, MachineService_GetMigrationStatus_FullMethodName, in, out, cOpts...)
	if err != nil {
		return nil, err
	}
	return out, nil
}

func (c *machineServiceClient) StreamMigrationProgress(ctx context.Context, in *MigrationStatusRequest, opts ...grpc.CallOption) (grpc.ServerStreamingClient[MigrationProgressEvent], error) {
	cOpts := append([]grpc.CallOption{grpc.StaticMethod()}, opts...)
	stream, err := c.cc.NewStream(ctx, &MachineService_ServiceDesc.Streams[0], MachineService_StreamMigrationProgress_FullMethodName, cOpts...)
	if err != nil {
		return nil, err
	}
	x := &grpc.GenericClientStream[MigrationStatusRequest, MigrationProgressEvent]{ClientStream: stream}
	if err := x.ClientStream.SendMsg(in); err != nil {
		return nil, err
	}
	if err := x.ClientStream.CloseSend(); err != nil {
		return nil, err
	}
	return x, nil
}

type MachineService_StreamMigrationProgressClient = grpc.ServerStreamingClient[MigrationProgressEvent]

type MachineServiceServer interface {
	Ping(context.Context, *PingRequest) (*PingResponse, error)
	CreateMachine(context.Context, *CreateRequest) (*CreateResponse, error)
	GetMachine(context.Context, *GetRequest) (*GetResponse, error)
	StartMachine(context.Context, *ActionRequest) (*ActionResponse, error)
	StopMachine(context.Context, *ActionRequest) (*ActionResponse, error)
	MigrateMachine(context.Context, *MigrateRequest) (*MigrateResponse, error)
	GetMigrationStatus(context.Context, *MigrationStatusRequest) (*MigrationStatusResponse, error)
	StreamMigrationProgress(*MigrationStatusRequest, grpc.ServerStreamingServer[MigrationProgressEvent]) error
	mustEmbedUnimplementedMachineServiceServer()
}

type UnimplementedMachineServiceServer struct{}

func (UnimplementedMachineServiceServer) Ping(context.Context, *PingRequest) (*PingResponse, error) {
	return nil, status.Errorf(codes.Unimplemented, "method Ping not implemented")
}
func (UnimplementedMachineServiceServer) CreateMachine(context.Context, *CreateRequest) (*CreateResponse, error) {
	return nil, status.Errorf(codes.Unimplemented, "method CreateMachine not implemented")
}
func (UnimplementedMachineServiceServer) GetMachine(context.Context, *GetRequest) (*GetResponse, error) {
	return nil, status.Errorf(codes.Unimplemented, "method GetMachine not implemented")
}
func (UnimplementedMachineServiceServer) StartMachine(context.Context, *ActionRequest) (*ActionResponse, error) {
	return nil, status.Errorf(codes.Unimplemented, "method StartMachine not implemented")
}
func (UnimplementedMachineServiceServer) StopMachine(context.Context, *ActionRequest) (*ActionResponse, error) {
	return nil, status.Errorf(codes.Unimplemented, "method StopMachine not implemented")
}
func (UnimplementedMachineServiceServer) MigrateMachine(context.Context, *MigrateRequest) (*MigrateResponse, error) {
	return nil, status.Errorf(codes.Unimplemented, "method MigrateMachine not implemented")
}
func (UnimplementedMachineServiceServer) GetMigrationStatus(context.Context, *MigrationStatusRequest) (*MigrationStatusResponse, error) {
	return nil, status.Errorf(codes.Unimplemented, "method GetMigrationStatus not implemented")
}
func (UnimplementedMachineServiceServer) StreamMigrationProgress(*MigrationStatusRequest, grpc.ServerStreamingServer[MigrationProgressEvent]) error {
	return status.Errorf(codes.Unimplemented, "method StreamMigrationProgress not implemented")
}
func (UnimplementedMachineServiceServer) mustEmbedUnimplementedMachineServiceServer() {}
func (UnimplementedMachineServiceServer) testEmbeddedByValue()                        {}

type UnsafeMachineServiceServer interface {
	mustEmbedUnimplementedMachineServiceServer()
}

func RegisterMachineServiceServer(s grpc.ServiceRegistrar, srv MachineServiceServer) {

	if t, ok := srv.(interface{ testEmbeddedByValue() }); ok {
		t.testEmbeddedByValue()
	}
	s.RegisterService(&MachineService_ServiceDesc, srv)
}

func _MachineService_Ping_Handler(srv interface{}, ctx context.Context, dec func(interface{}) error, interceptor grpc.UnaryServerInterceptor) (interface{}, error) {
	in := new(PingRequest)
	if err := dec(in); err != nil {
		return nil, err
	}
	if interceptor == nil {
		return srv.(MachineServiceServer).Ping(ctx, in)
	}
	info := &grpc.UnaryServerInfo{
		Server:     srv,
		FullMethod: MachineService_Ping_FullMethodName,
	}
	handler := func(ctx context.Context, req interface{}) (interface{}, error) {
		return srv.(MachineServiceServer).Ping(ctx, req.(*PingRequest))
	}
	return interceptor(ctx, in, info, handler)
}

func _MachineService_CreateMachine_Handler(srv interface{}, ctx context.Context, dec func(interface{}) error, interceptor grpc.UnaryServerInterceptor) (interface{}, error) {
	in := new(CreateRequest)
	if err := dec(in); err != nil {
		return nil, err
	}
	if interceptor == nil {
		return srv.(MachineServiceServer).CreateMachine(ctx, in)
	}
	info := &grpc.UnaryServerInfo{
		Server:     srv,
		FullMethod: MachineService_CreateMachine_FullMethodName,
	}
	handler := func(ctx context.Context, req interface{}) (interface{}, error) {
		return srv.(MachineServiceServer).CreateMachine(ctx, req.(*CreateRequest))
	}
	return interceptor(ctx, in, info, handler)
}

func _MachineService_GetMachine_Handler(srv interface{}, ctx context.Context, dec func(interface{}) error, interceptor grpc.UnaryServerInterceptor) (interface{}, error) {
	in := new(GetRequest)
	if err := dec(in); err != nil {
		return nil, err
	}
	if interceptor == nil {
		return srv.(MachineServiceServer).GetMachine(ctx, in)
	}
	info := &grpc.UnaryServerInfo{
		Server:     srv,
		FullMethod: MachineService_GetMachine_FullMethodName,
	}
	handler := func(ctx context.Context, req interface{}) (interface{}, error) {
		return srv.(MachineServiceServer).GetMachine(ctx, req.(*GetRequest))
	}
	return interceptor(ctx, in, info, handler)
}

func _MachineService_StartMachine_Handler(srv interface{}, ctx context.Context, dec func(interface{}) error, interceptor grpc.UnaryServerInterceptor) (interface{}, error) {
	in := new(ActionRequest)
	if err := dec(in); err != nil {
		return nil, err
	}
	if interceptor == nil {
		return srv.(MachineServiceServer).StartMachine(ctx, in)
	}
	info := &grpc.UnaryServerInfo{
		Server:     srv,
		FullMethod: MachineService_StartMachine_FullMethodName,
	}
	handler := func(ctx context.Context, req interface{}) (interface{}, error) {
		return srv.(MachineServiceServer).StartMachine(ctx, req.(*ActionRequest))
	}
	return interceptor(ctx, in, info, handler)
}

func _MachineService_StopMachine_Handler(srv interface{}, ctx context.Context, dec func(interface{}) error, interceptor grpc.UnaryServerInterceptor) (interface{}, error) {
	in := new(ActionRequest)
	if err := dec(in); err != nil {
		return nil, err
	}
	if interceptor == nil {
		return srv.(MachineServiceServer).StopMachine(ctx, in)
	}
	info := &grpc.UnaryServerInfo{
		Server:     srv,
		FullMethod: MachineService_StopMachine_FullMethodName,
	}
	handler := func(ctx context.Context, req interface{}) (interface{}, error) {
		return srv.(MachineServiceServer).StopMachine(ctx, req.(*ActionRequest))
	}
	return interceptor(ctx, in, info, handler)
}

func _MachineService_MigrateMachine_Handler(srv interface{}, ctx context.Context, dec func(interface{}) error, interceptor grpc.UnaryServerInterceptor) (interface{}, error) {
	in := new(MigrateRequest)
	if err := dec(in); err != nil {
		return nil, err
	}
	if interceptor == nil {
		return srv.(MachineServiceServer).MigrateMachine(ctx, in)
	}
	info := &grpc.UnaryServerInfo{
		Server:     srv,
		FullMethod: MachineService_MigrateMachine_FullMethodName,
	}
	handler := func(ctx context.Context, req interface{}) (interface{}, error) {
		return srv.(MachineServiceServer).MigrateMachine(ctx, req.(*MigrateRequest))
	}
	return interceptor(ctx, in, info, handler)
}

func _MachineService_GetMigrationStatus_Handler(srv interface{}, ctx context.Context, dec func(interface{}) error, interceptor grpc.UnaryServerInterceptor) (interface{}, error) {
	in := new(MigrationStatusRequest)
	if err := dec(in); err != nil {
		return nil, err
	}
	if interceptor == nil {
		return srv.(MachineServiceServer).GetMigrationStatus(ctx, in)
	}
	info := &grpc.UnaryServerInfo{
		Server:     srv,
		FullMethod: MachineService_GetMigrationStatus_FullMethodName,
	}
	handler := func(ctx context.Context, req interface{}) (interface{}, error) {
		return srv.(MachineServiceServer).GetMigrationStatus(ctx, req.(*MigrationStatusRequest))
	}
	return interceptor(ctx, in, info, handler)
}

func _MachineService_StreamMigrationProgress_Handler(srv interface{}, stream grpc.ServerStream) error {
	m := new(MigrationStatusRequest)
	if err := stream.RecvMsg(m); err != nil {
		return err
	}
	return srv.(MachineServiceServer).StreamMigrationProgress(m, &grpc.GenericServerStream[MigrationStatusRequest, MigrationProgressEvent]{ServerStream: stream})
}

type MachineService_StreamMigrationProgressServer = grpc.ServerStreamingServer[MigrationProgressEvent]

var MachineService_ServiceDesc = grpc.ServiceDesc{
	ServiceName: "aerophoenix.machine.MachineService",
	HandlerType: (*MachineServiceServer)(nil),
	Methods: []grpc.MethodDesc{
		{
			MethodName: "Ping",
			Handler:    _MachineService_Ping_Handler,
		},
		{
			MethodName: "CreateMachine",
			Handler:    _MachineService_CreateMachine_Handler,
		},
		{
			MethodName: "GetMachine",
			Handler:    _MachineService_GetMachine_Handler,
		},
		{
			MethodName: "StartMachine",
			Handler:    _MachineService_StartMachine_Handler,
		},
		{
			MethodName: "StopMachine",
			Handler:    _MachineService_StopMachine_Handler,
		},
		{
			MethodName: "MigrateMachine",
			Handler:    _MachineService_MigrateMachine_Handler,
		},
		{
			MethodName: "GetMigrationStatus",
			Handler:    _MachineService_GetMigrationStatus_Handler,
		},
	},
	Streams: []grpc.StreamDesc{
		{
			StreamName:    "StreamMigrationProgress",
			Handler:       _MachineService_StreamMigrationProgress_Handler,
			ServerStreams: true,
		},
	},
	Metadata: "machine.proto",
}
