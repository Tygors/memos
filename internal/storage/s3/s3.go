package s3

import (
	"bytes"
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
	})
	return &Client{
		Client: client,
		Bucket: aws.String(s3Config.Bucket),
	}, nil
}

// UploadObject uploads content to S3 using a presigned PUT URL.  The
// presigned URL includes the signature in query parameters, so the actual
// HTTP PUT does not need SigV4 signing and MinIO's content-SHA256
// constraint does not apply.
func (c *Client) UploadObject(ctx context.Context, key string, fileType string, content io.Reader) (string, error) {
	presignClient := s3.NewPresignClient(c.Client)
	presignResult, err := presignClient.PresignPutObject(ctx, &s3.PutObjectInput{
		Bucket:      c.Bucket,
		Key:         aws.String(key),
		ContentType: aws.String(fileType),
	}, func(opts *s3.PresignOptions) {
		opts.Expires = 15 * time.Minute
	})
	if err != nil {
		return "", errors.Wrap(err, "failed to presign put object")
	}

	body, err := io.ReadAll(content)
	if err != nil {
		return "", errors.Wrap(err, "failed to read content")
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPut, presignResult.URL, bytes.NewReader(body))
	if err != nil {
		return "", errors.Wrap(err, "failed to create request")
	}
	req.Header.Set("Content-Type", fileType)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", errors.Wrap(err, "failed to send request")
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		respBody, _ := io.ReadAll(resp.Body)
		return "", errors.Errorf("upload failed: %d %s", resp.StatusCode, string(respBody))
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
