output "a_public_ip" {
  value = aws_instance.a_vote_result.public_ip
}

output "b_private_ip" {
  value = aws_instance.b_redis_worker.private_ip
}

output "c_private_ip" {
  value = aws_instance.c_postgres.private_ip
}

output "region" {
  value = data.aws_region.current.id
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}
