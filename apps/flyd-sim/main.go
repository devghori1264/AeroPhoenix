package main

import (
	"context"
	"fmt"
	"log"
	"net"

	pb "/aerophoenix/proto/machine.proto" // adjust module path

	"google.golang.org/grpc"
)

type server struct {
	pb.UnimplementedMachineServiceServer
}

func (s *server) Ping(ctx context.Context, req *pb.PingRequest) (*pb.PingResponse, error) {
	return &pb.PingResponse{Msg: "pong from flyd-sim"}, nil
}

func main() {
	lis, err := net.Listen("tcp", ":50051")
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}
	grpcServer := grpc.NewServer()
	pb.RegisterMachineServiceServer(grpcServer, &server{})
	fmt.Println("flyd-sim gRPC server listening on :50051")
	if err := grpcServer.Serve(lis); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}
