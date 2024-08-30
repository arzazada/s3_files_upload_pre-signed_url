import json
import boto3
import os
from botocore.exceptions import ClientError

s3_client = boto3.client('s3')

def lambda_handler(event, context):
    bucket_name = os.environ['BUCKET_NAME']
    object_name = event['queryStringParameters']['file_name']
    expiration = 3600  # 1 hour expiration

    try:
        response = s3_client.generate_presigned_url('put_object',
                                                    Params={'Bucket': bucket_name, 'Key': object_name},
                                                    ExpiresIn=expiration)
    except ClientError as e:
        return {
            'statusCode': 500,
            'body': json.dumps(str(e))
        }

    return {
        'statusCode': 200,
        'body': json.dumps({'url': response})
    }
