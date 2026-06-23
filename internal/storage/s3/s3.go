package s3

import (
	"context"
	"crypto/tls"
	"io"
	"net/http"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/smithy-go/middleware"
	smithyhttp "github.com/aws/smithy-go/transport/http"
	"github.com/pkg/errors"

	storepb "github.com/usememos/memos/proto/gen/store"
)

type Client struct {
	Client *s3.Client
	Bucket *string
}

func NewClient(ctx context.Context, s3Config *storepb.StorageS3Config) (*Client, error) {
	loadOptions := []func(*config.LoadOptions) error{
		config.WithCredentialsProvider(credentials.NewStaticCredentialsProvider(s3Config.AccessKeyId, s3Config.AccessKeySecret, "")),
		config.WithRegion(s3Config.Region),
	}

	// Custom HTTP transport: disable HTTP/2 for better compatibility
	// with S3-compatible storage (MinIO, etc.), and optionally skip
	// TLS verification for self-signed certificates.
	httpClient := awshttp.NewBuildableClient().WithTransportOptions(func(tr *http.Transport) {
		tr.ForceAttemptHTTP2 = false
		if s3Config.InsecureSkipTlsVerify {
			tr.TLSClientConfig = &tls.Config{InsecureSkipVerify: true}
		}
	})
	loadOptions = append(loadOptions, config.WithHTTPClient(httpClient))

	cfg, err := config.LoadDefaultConfig(ctx, loadOptions...)
	if err != nil {
		return nil, errors.Wrap(err, "failed to load s3 config")
	}

	client := s3.NewFromConfig(cfg, func(o *s3.Options) {
		o.BaseEndpoint = aws.String(s3Config.Endpoint)
		o.UsePathStyle = s3Config.UsePathStyle

		// Inject a build-phase middleware that sets x-amz-content-sha256
		// to "UNSIGNED-PAYLOAD".  This runs before SigV4 signing so the
		// header value is included in the canonical request.  Required by
		// MinIO and other S3-compatible stores that do not accept a
		// computed payload hash over plain HTTP.
		o.APIOptions = append(o.APIOptions, func(stack *middleware.Stack) error {
			return stack.Build.Add(
				middleware.BuildMiddlewareFunc("UnsignedPayload", func(
					ctx context.Context,
					in middleware.BuildInput,
					next middleware.BuildHandler,
				) (middleware.BuildOutput, middleware.Metadata, error) {
					if req, ok := in.Request.(*smithyhttp.Request); ok {
						req.Header.Set("x-amz-content-sha256", "UNSIGNED-PAYLOAD")
					}
					return next.HandleBuild(ctx, in)
				}),
				middleware.Before,
			)
		})
	})
	return &Client{
		Client: client,
		Bucket: aws.String(s3Config.Bucket),
	}, nil
}

func (c *Client) UploadObject(ctx context.Context, key string, fileType string, content io.Reader) (string, error) {
	putInput := s3.PutObjectInput{
		Bucket:      c.Bucket,
		Key:         aws.String(key),
		ContentType: aws.String(fileType),
		Body:        content,
	}
	if _, err := c.Client.PutObject(ctx, &putInput); err != nil {
		return "", err
	}
	return key, nil
}

func (c *Client) PresignGetObject(ctx context.Context, key string) (string, error) {
	presignClient := s3.NewPresignClient(c.Client)
	presignResult, err := presignClient.PresignGetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(*c.Bucket),
		Key:    aws.String(key),
	}, func(opts *s3.PresignOptions) {
		opts.Expires = time.Duration(5 * 24 * time.Hour)
	})
	if err != nil {
		return "", errors.Wrap(err, "failed to presign get object")
	}
	return presignResult.URL, nil
}

func (c *Client) GetObject(ctx context.Context, key string) ([]byte, error) {
	output, err := c.Client.GetObject(ctx, &s3.GetObjectInput{
		Bucket: c.Bucket,
		Key:    aws.String(key),
	})
	if err != nil {
		return nil, errors.Wrap(err, "failed to download object")
	}
	defer output.Body.Close()
	data, err := io.ReadAll(output.Body)
	if err != nil {
		return nil, errors.Wrap(err, "failed to read object body")
	}
	return data, nil
}

func (c *Client) GetObjectStream(ctx context.Context, key string) (io.ReadCloser, error) {
	output, err := c.Client.GetObject(ctx, &s3.GetObjectInput{
		Bucket: c.Bucket,
		Key:    aws.String(key),
	})
	if err != nil {
		return nil, errors.Wrap(err, "failed to get object")
	}
	return output.Body, nil
}

func (c *Client) DeleteObject(ctx context.Context, key string) error {
	_, err := c.Client.DeleteObject(ctx, &s3.DeleteObjectInput{
		Bucket: c.Bucket,
		Key:    aws.String(key),
	})
	if err != nil {
		return errors.Wrap(err, "failed to delete object")
	}
	return nil
}
