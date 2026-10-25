-- create_orders: the quick start's own table, beside spool's.

create table orders (
  id     bigint generated always as identity primary key,
  email  text not null
);
